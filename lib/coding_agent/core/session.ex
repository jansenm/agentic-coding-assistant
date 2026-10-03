defmodule CodingAgent.Core.Session do
  @moduledoc """
  One agent session: an OTP process owning one conversation.

  Implements the agent loop from `docs/source/explanation/agent-loop.rst`.
  A tool-call turn runs the tools through the permission gate and
  continues the loop; a call that needs a human parks the round as
  `:interrupted` until `decide/2`.

  The session state is plain data (ADR 003: everything is data so
  persistence and interruption become states, not exceptions).

  ## The session stays responsive while a turn runs

  A turn is one long stretch of blocking I/O (provider streaming, tool
  execution, compaction). Running it inline in this GenServer froze the
  mailbox for the turn's duration — `state/1` and `set_agent/2` queued
  behind it and the TUI hung on Tab (found live). The blocking loop now
  runs in a supervised worker task (`Session.TurnTaskSupervisor`): this
  process owns the durable state, starts the worker, keeps answering
  calls, and merges the worker's final state when it reports back.
  `run/2` and `decide/2` still return synchronously TO THE CALLER via
  `GenServer.reply/2`; only the session process is unblocked.

  Calls that arrive while a turn is in flight (another `run`, a gate
  `decide`, or an agent/model switch) are queued and applied at the
  turn boundary, preserving the one-turn-at-a-time semantics without
  blocking.

  Separation of concerns within `CodingAgent.Core.Session.*`:

  - this module — the loop: turn lifecycle, tool gating, interrupts,
    event broadcast;
  - `CodingAgent.Core.Session.Compactor` — the compaction operation
    (trigger decision, summarize call, backoff);
  - `CodingAgent.Core.Session.Request` — wire-request assembly
    (model spec, providers, credentials) shared by every LLM call site;
  - `CodingAgent.Core.Session.Store` — persistence.
  """

  use GenServer

  require Logger

  alias CodingAgent.Core.Compaction
  alias CodingAgent.Core.Config
  alias CodingAgent.Core.Checkpoint
  alias CodingAgent.Core.Events
  alias CodingAgent.Core.Interrupt
  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.ToolCall
  alias CodingAgent.Core.Tools.Question

  alias CodingAgent.Core.Session.{
    Compactor,
    Gate,
    Prompt,
    Request,
    State,
    Store,
    ToolRunner,
    Usage
  }

  alias ReqLLM.Context

  # GenServer call timeout. Gate decisions can take arbitrarily long
  # (the user is a human reading the approval prompt), so decide/2 and
  # friends use :infinity. The LLM call inside a turn is bounded by the
  # provider's own timeouts, not this one.
  @call_timeout :infinity

  # How many consecutive identical tool ROUNDS constitute a doom loop
  # (ADR 026). opencode's DOOM_LOOP_THRESHOLD is 3 (processor.ts), though
  # it counts stream parts; we count rounds. The same value.
  @doom_loop_window 3

  # The per-turn tool-round budget (ADR 025): an agent definition's
  # max_turns when set, else the session's config.toml-resolved value,
  # else the app-env default. The guard exists to catch a runaway loop,
  # and its cost is proportional to the work actually requested.
  defp tool_budget(state) do
    State.tool_budget(state) || CodingAgent.Core.Config.max_tool_rounds()
  end

  # -- Client API -------------------------------------------------------------

  @doc "Starts a session process as part of the supervision tree."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc """
  A fresh default session id. Globally unique (a ULID, not
  `System.unique_integer`, which restarts at the same base in every VM):
  the id names git checkpoint refs in a repo shared across worktrees and
  stores (review N61), so two VMs rolling the same counter could collide
  and make reconciliation keep the wrong session's refs.
  """
  @spec new_id() :: String.t()
  def new_id, do: "tui-" <> ulid()

  # A ULID-shaped, lexicographically sortable id with 80 bits of entropy in
  # the random suffix — enough that the cross-VM collision the integer
  # counter allowed cannot happen. Pure Elixir, no dependency.
  defp ulid do
    ts = System.system_time(:millisecond)
    <<r1::unsigned-40, r2::unsigned-40>> = :crypto.strong_rand_bytes(10)
    base36(ts, 10) <> base36(r1, 8) <> base36(r2, 8)
  end

  defp base36(n, width), do: n |> Integer.to_string(36) |> String.pad_leading(width, "0")

  @doc """
  Returns the session's current state (messages, status).

  Degrades instead of raising (the TUI reads the session from many
  render/key paths): a gone session (`:noproc`), a normal shutdown, or a
  `:timeout` on a busy one reads as `{:error, :not_found | :timeout}`.
  Note that an unexpected `:exit` — a real crash in the session process —
  also reads as `:not_found`; it is logged at error level so the crash is
  not entirely silent. All callers branch on `{:error, _}`.
  """
  @spec state(String.t()) :: {:ok, State.t()} | {:error, :not_found | :timeout}
  def state(id), do: safe_call(id, :state, "state read", 5_000)

  @doc """
  Updates the LIVE session's in-memory id after a Store rename so its
  next save lands under the new name (no stale-file resurrection).
  The registry keeps the old key — the process remains addressable
  under the id it was started with until it exits; future mounts go
  through the renamed file.
  """
  def set_id(id, new_id) do
    safe_call(id, {:set_id, new_id}, "set_id", @call_timeout)
  end

  @doc "Model-menu switch: swap the wire model for the NEXT turn."
  def set_model(id, model) do
    safe_call(id, {:set_model, model}, "set_model", @call_timeout)
  end

  @doc """
  Switches the agent for the NEXT turn (ADR 017/018: the "next" slot).
  A turn already in flight keeps the agent it started with.

  Recomputes the policy and system prompt from the session's base values,
  so switching A -> B never compounds A's restrictions onto B (the
  permission merge is narrowing, not idempotent). Passing `nil` clears
  the agent back to the base policy and framework prompt.
  """
  @spec set_agent(String.t(), String.t() | nil) :: {:ok, State.t()} | {:error, term()}
  def set_agent(id, name) do
    safe_call(id, {:set_agent, name}, "set_agent", @call_timeout)
  end

  @doc """
  Subscribes the CALLER to session events (streaming deltas, status
  changes). Events arrive as `{:agent, id, event}` messages, where `id`
  is the SOURCE session id (ADR 018): a subscriber watching a parent and
  its subagent children routes on the tag instead of blending the two.

  Registry registration is process-local, so it must happen in the
  caller — the historical :subscribe call registered the *session*
  process instead (bug found by the TUI in 5a: the first real event
  consumer; the CLI never noticed because run/2 returns the final
  state and the deltas path was silently empty).
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(id) do
    _ = Registry.register(CodingAgent.EventRegistry, {Events.key(), id}, nil)
    GenServer.call(via(id), :subscribe)
  end

  @doc """
  The `start_session/1` options that resume a persisted state.

  This is the canonical resume mapping: callers (CLI, TUI) hand over the
  loaded `%State{}` and do not reconstruct fields themselves, so adding a
  state field does not force an edit in every driver. The rules encoded
  here:

    * the BASE policy is restored, not the agent-narrowed one — resuming
      a plan session with its narrowed policy would make the restrictions
      permanent (`set_agent` recomputes from base);
    * the persisted agent is restored only when its definition still
      exists (and is a primary); a deleted definition resumes without an
      agent rather than raising;
    * usage/warned/backoff and the parked-round fields carry forward.

  `overrides` are merged last: a driver may force a different `:agent`
  (the CLI's explicit `--agent`).
  """
  @spec resume_opts(State.t(), keyword()) :: keyword()
  def resume_opts(%State{} = state, overrides \\ []) do
    [
      id: state.id,
      context: state.context,
      model: state.model,
      scope_root: state.scope_root,
      policy: state.base_policy || state.policy,
      agent: resumable_agent_name(state),
      # carry the caller's prompt override so a model switch after resume
      # recomposes from it rather than falling back to the model file
      # (ADR 024)
      system_prompt: state.prompt_override,
      usage: state.usage,
      compaction_warned: state.compaction_warned,
      compaction_backoff: state.compaction_backoff,
      status: state.status,
      pending_tool_calls: state.pending_tool_calls,
      pending_round_calls: state.pending_round_calls,
      pending_round_results: state.pending_round_results,
      # a budget pause is durable: the held round and the question resume
      budget_pause: state.budget_pause,
      # a doom-loop pause is durable the same way (ADR 026)
      doom_pause: state.doom_pause,
      # a question pause is durable too (ADR 027)
      question_pause: state.question_pause,
      # the model's todo list is durable (ADR 031)
      todos: state.todos,
      # subagent seams (ADR 017/018): a resumed primary keeps depth 0;
      # a resumed child would too (children are ephemeral and not resumed)
      depth: state.depth,
      persist?: state.persist?
    ]
    |> Keyword.merge(overrides)
  end

  @doc """
  Resumes a persisted state under the session supervisor. Returns
  `{:ok, pid}` or the supervisor's error. The caller subscribes if it
  wants events.
  """
  @spec resume(State.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def resume(%State{} = state, overrides \\ []) do
    CodingAgent.Core.Session.Supervisor.start_session(resume_opts(state, overrides))
  end

  @doc """
  Stops a live session process. Used by the subagent seam to retire a
  finished child (it ran once, its summary is extracted, and it must not
  linger idle under the supervisor: `restart: :transient` means a normal
  stop is not restarted). Best effort — an already-gone child is fine.
  """
  @spec stop(String.t()) :: :ok
  def stop(id) do
    case Registry.lookup(CodingAgent.Registry, {:session, id}) do
      [{pid, _}] -> GenServer.stop(pid, :normal, 5_000)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  Tells a LIVE session (if one is registered under `old_id`) its new id
  after a `Store.rename/2`, so its next save lands on the renamed file.

  This lives here, not in `Store`: persistence must not depend on the
  process registry, and only the session layer knows how to reach a live
  process.
  """
  @spec notify_renamed(String.t(), String.t()) :: :ok
  def notify_renamed(old_id, new_id) do
    case Registry.lookup(CodingAgent.Registry, {:session, old_id}) do
      [{_pid, _}] -> set_id(old_id, new_id)
      _ -> :ok
    end
  end

  # The persisted agent name, or nil when the definition is gone / not
  # human-selectable (ADR 029: subagent-only or hidden). A missing
  # definition must not brick a resume; neither must a definition that
  # stopped being selectable since the session ran.
  defp resumable_agent_name(%State{agent: nil}), do: nil

  defp resumable_agent_name(%State{agent: %{name: name}, scope_root: root}) do
    case Config.agents(root) do
      {:ok, agents} ->
        if Enum.any?(agents, &(&1.name == name and CodingAgent.Core.Agent.selectable?(&1))),
          do: name,
          else: nil

      _ ->
        nil
    end
  end

  @doc """
  Runs one turn: sends the user prompt to the model and streams the
  answer to subscribers. Blocks until the turn finishes and returns the
  resulting state.

  The RETURN is synchronous for the caller, but the session process is
  NOT blocked: the turn's blocking loop (provider streaming, tools,
  compaction) runs in a supervised worker task. The session keeps
  answering `state/1`, `set_agent/2`, `interrupt/1` and `decide/2`
  while it streams.
  """
  @spec run(String.t(), String.t()) :: {:ok, State.t()} | {:error, term()}
  def run(id, prompt), do: GenServer.call(via(id), {:run, prompt}, @call_timeout)

  @doc """
  Interrupts a running turn (user stop request, opencode's esc).

  Delegates to `CodingAgent.Core.Interrupt`, which owns the flag and the
  active stream's cancel handle. This is a thin convenience so callers
  (the TUI) don't need to know the coordinator module.
  """
  @spec interrupt(String.t()) :: :ok
  defdelegate interrupt(id), to: CodingAgent.Core.Interrupt, as: :request

  @doc """
  Restores the worktree to the newest checkpoint (ADR 036, `/undo`).
  See `CodingAgent.Core.Checkpoint` for the mechanism.

  Returns `{:ok, n}` where `n` is the number of checkpoints left, or
  `{:error, :nothing_to_undo}` when the session has none. Refused while a
  turn is in flight (`{:error, :busy}`) — undo is a boundary verb.
  """
  @spec undo(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def undo(id), do: safe_call(id, :undo, "undo", @call_timeout)

  @doc """
  Manually compacts the context now (`/compact`, ctrl-x c): summarize the
  older span regardless of the soft/hard limits (ADR 037's automatic
  passes stay the default; this is the human's on-demand verb).

  The summary is a slow provider call, so it runs in a background task
  like the idle soft pass; the reply reports what was STARTED, not the
  finished summary. Returns `:not_running` when a turn is in flight (a
  boundary verb, like `/undo`), `:nothing` when there is no whole old
  exchange to summarize.
  """
  @spec compact(String.t()) ::
          :started | :turn_running | :already_compacting | :nothing | {:error, term()}
  def compact(id), do: safe_call(id, :compact, "compact", @call_timeout)

  @doc """
  Supplies decisions for pending tool calls (ADR 010: approve / edit /
  reject, one decision per call) and resumes the interrupted turn.
  """
  @spec decide(String.t(), [%{id: String.t(), decision: :approve | :reject | {:edit, map()}}]) ::
          {:ok, State.t()} | {:error, term()}
  def decide(id, decisions), do: safe_call(id, {:decide, decisions}, "decide", @call_timeout)

  @doc """
  Answers the tool-round budget prompt (ADR 025).

  `:continue` runs the round that tripped the budget under a FRESH budget
  (another full allowance) — the round's calls were held, so nothing is
  lost. `:stop` wraps up: the held round is discarded and the model is
  asked to summarize, exactly as a non-interactive driver experiences it.

  Only valid while the session is parked at `:budget_reached`; any other
  state returns `{:error, {:not_at_budget, status}}`.
  """
  @spec budget_decision(String.t(), :continue | :stop) :: {:ok, State.t()} | {:error, term()}
  def budget_decision(id, decision) when decision in [:continue, :stop] do
    safe_call(id, {:budget_decision, decision}, "budget_decision", @call_timeout)
  end

  @doc """
  Answers the doom-loop prompt (ADR 026).

  `:continue` runs the repeated round anyway (the user judges the
  repetition correct). `:reject` does not run it: every held call is
  answered with a synthetic tool result steering the model off the
  repetition, and the turn continues.

  Only valid while parked at `:doom_reached`; any other state returns
  `{:error, {:not_at_doom, status}}`.
  """
  @spec doom_decision(String.t(), :continue | :reject) :: {:ok, State.t()} | {:error, term()}
  def doom_decision(id, decision) when decision in [:continue, :reject] do
    safe_call(id, {:doom_decision, decision}, "doom_decision", @call_timeout)
  end

  @doc """
  Answers a question the model asked (ADR 027).

  `answers` is one list of selected labels per question, in order —
  `[["A"], ["B", "C"]]` for two questions. An empty list means the
  question was left unanswered (the model sees `Unanswered`). The held
  round then runs with the question results pre-known.

  Only valid while parked on a question; any other state returns
  `{:error, {:not_at_question, status}}`.
  """
  @spec answer_question(String.t(), [[String.t()]]) :: {:ok, State.t()} | {:error, term()}
  def answer_question(id, answers) when is_list(answers) do
    safe_call(id, {:answer_question, answers}, "answer_question", @call_timeout)
  end

  @doc """
  Feeds tool calls directly into the permission gate, bypassing the
  LLM. Test-only hook (phase-2 test support); not part of the public
  driver contract. Refuses a non-test session with
  `{:error, :not_test_mode}` — it must never silently turn a live
  session into a test-mode one.

  `opts` may set `:rounds` to simulate a turn that has already burned
  that many tool rounds (default 0), so the budget path (ADR 025) is
  reachable without a provider.
  """
  @doc since: "0.1.0"
  @spec debug_gate(String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def debug_gate(id, calls, opts \\ []) when is_list(calls) do
    GenServer.call(via(id), {:debug_gate, calls, opts}, @call_timeout)
  end

  defp via(id), do: {:via, Registry, {CodingAgent.Registry, {:session, id}}}

  # A session call that must never kill its caller (review N7). The TUI
  # invokes the action verbs — `/compact`, `/undo`, the model/agent switch,
  # the question/budget/doom replies — bare from key paths; an uncaught
  # `:exit` on a gone session (`:noproc`, e.g. after an orderly
  # `Session.stop/1` elsewhere) or a momentarily busy one terminates the
  # whole TUI server. Every public call degrades to `{:error, :not_found |
  # :timeout}` instead, so the caller's `{:error, _}` branch (or a
  # catch-all) reports it. `state/1` already did this; this is the same
  # policy for the action side.
  defp safe_call(id, request, label, timeout) do
    GenServer.call(via(id), request, timeout)
  catch
    :exit, {:noproc, _} ->
      {:error, :not_found}

    :exit, {:normal, _} ->
      {:error, :not_found}

    :exit, {:timeout, _} ->
      Logger.warning("session #{id} #{label} timed out")
      {:error, :timeout}

    :exit, reason ->
      Logger.error("session #{id} #{label} exited: #{inspect(reason)}")
      {:error, :not_found}
  end

  # Test-only handle on the turn-completion path, so a test can drive a
  # streamed turn (ordered reasoning/answer blocks) without a provider.
  # Used from a `turn_runner` closure. Not part of the driver contract.
  @doc false
  @spec debug_complete_turn(State.t(), String.t(), [{atom(), String.t()}]) :: State.t()
  def debug_complete_turn(state, text, blocks), do: complete_turn(state, text, blocks)

  # -- Server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    scope_root = Keyword.get(opts, :scope_root)

    # ONE typed read of the layered file config (Core.Config): merged
    # config/ui, permissions, mounts, providers and agent definitions.
    # `load/1` already merged permissions and (with cached layers)
    # mounts; the old code read the same files three times through
    # three paths (init and load_policy).
    snapshot = Config.snapshot(scope_root)

    # no model in code (user decision): a fresh session needs the
    # configured default; nil fails loudly here (the TUI guard usually
    # catches this first)
    model =
      Keyword.get(opts, :model) ||
        Config.model(snapshot) ||
        raise(Config.no_model_message())

    # ADR 030: a confining sandbox is a precondition for EVERY session,
    # test or production. There is no unconfined operating mode; the
    # suite selects a confining test double in config/test.exs (and
    # `Sandbox.None` only for the refusal path itself). A raise here is
    # an init failure, not a crash: `start_session/1` returns a readable
    # `{:error, reason}` either way.
    unless CodingAgent.Core.Sandbox.confines?() do
      raise CodingAgent.Core.Sandbox.refusal_message()
    end

    test_mode = Keyword.get(opts, :test_mode, false)
    policy = Keyword.get(opts, :policy) || snapshot.permissions

    # Drop checkpoint refs of sessions that are GONE (review N54): a killed
    # TUI leaves refs behind, and (before N53) each pinned its whole tree.
    # Best effort; a non-git or unwritable root is a no-op. Runs OFF the
    # start path (review N63): `Checkpoint.reconcile/2` shells out to a
    # confined `git for-each-ref` with a 60 s timeout, so a cold bwrap start
    # or a stalled git would hold `Session.start_link` — and thus every
    # session start — for up to a minute with no UI feedback. This id is
    # passed explicitly, so this session is always in the keep-set even
    # though the pass now runs after registration.
    schedule_checkpoint_reconcile(scope_root, id)

    # Resume support (4a): a resumed session must carry the persisted
    # usage forward. last_input_tokens is the ONLY sound compaction
    # measure; without it decide/2 takes the chars fallback and compacts
    # a just-resumed session on its first command regardless of the real
    # token count (found live: every resumed session compacted at once).
    usage = Usage.from_map(Keyword.get(opts, :usage))
    compaction_warned = Keyword.get(opts, :compaction_warned, false)
    compaction_backoff = Keyword.get(opts, :compaction_backoff, 0)
    # test seam: replace the worker's blocking body. Lets a test hold a
    # turn "in flight" (and assert the session still answers) without a
    # provider. Never set in production.
    turn_runner = Keyword.get(opts, :turn_runner)
    # test seam for the CHILD session a `task` call starts (ADR 017/018):
    # the child's blocking body. Never set in production.
    subagent_runner = Keyword.get(opts, :subagent_runner)
    # test seam for the background IDLE compaction pass (ADR 037): the
    # body that would summarize. Never set in production.
    idle_compaction_runner = Keyword.get(opts, :idle_compaction_runner)

    # A session that was parked at the gate when it last stopped resumes
    # PARKED, not idle: the pending calls (and the half of the round that
    # was already decided — auto-executed, blacklist/policy-denied) come
    # back so `decide/2` can finish the exchange. Dropping them used to
    # silently discard work the user then had to redo.
    #
    # Status and round agree BY CONSTRUCTION: a round is held exactly
    # while the session is parked at :interrupted, and a state that says
    # otherwise is not a pause to re-offer but a corrupt one (found live:
    # `:idle` + a held webfetch round, which the UI showed as a session
    # with no prompt and no running turn). Drop the hold and let the
    # consequence be visible — the model reads the call as unanswered on
    # its next turn — rather than parking the session behind a dialog
    # nobody can reach.
    {status, pending_tool_calls, pending_round_calls, pending_round_results} =
      if Keyword.get(opts, :status, :idle) == :interrupted do
        {
          :interrupted,
          Keyword.get(opts, :pending_tool_calls, []),
          Keyword.get(opts, :pending_round_calls, []),
          Keyword.get(opts, :pending_round_results, [])
        }
      else
        {:idle, [], [], []}
      end

    # The system prompt is framework + project memory (4c, AGENTS.md) +
    # the agent definition's prompt (ADR 017), composed by Session.Prompt.
    # base_policy/base_prompt are the values BEFORE the agent layer, kept
    # so a later set_agent/2 (Tab switch) recomputes from scratch:
    # apply_agent narrows, so stacking a second definition would compound
    # the first's restrictions.
    base_policy = policy
    # The framework prompt is selected for the model (ADR 024), so
    # `base_prompt` depends on it; a model switch recomposes (set_model /
    # apply_pending_switches). A caller-supplied override wins over the
    # model file and is kept for that recomposition.
    prompt_override = Keyword.get(opts, :system_prompt)
    base_prompt = Prompt.base(prompt_override, scope_root, model)

    {agent, policy, system_prompt} =
      case resolve_agent(Keyword.get(opts, :agent), policy, base_prompt, snapshot.agents) do
        {:ok, agent, policy, prompt} -> {agent, policy, prompt}
        {:error, reason} -> raise ArgumentError, format_agent_error(reason)
      end

    # The compaction window and its two limits (ADR 037), resolved from the
    # layered config / catalog / fallback and stored on the state, so the
    # sidebar, the warning and the decision read the same numbers (ADR 029
    # — the display must not re-derive what the decision uses). Resolved
    # against the EFFECTIVE model: an agent definition may pin its own
    # model (ADR 017), and the switch re-resolves later.
    #
    # ADR 039: the catalog lookup is non-blocking. It is loaded in the
    # background at app boot, so a mount that races the warm gets the
    # configured/fallback window NOW (never the ~3.7s cold load) and
    # re-resolves when the catalog signals readiness — hence the
    # subscription below. A configured `context_window` always wins, so it
    # need not listen.
    effective_model =
      case agent do
        %{model: pinned} when is_binary(pinned) and pinned != "" -> pinned
        _ -> model
      end

    {{window, soft_limit, hard_limit}, window_source} =
      Config.compaction_limits_resolved(snapshot, effective_model)

    unless Config.context_window_configured?(snapshot) do
      CodingAgent.Core.Providers.Catalog.subscribe()
    end

    # Resume support (4a): a caller may pass a persisted :context (and
    # then model/policy come from the snapshot too); otherwise a fresh
    # context with the framework system prompt is created.
    #
    # A restored context is sanitized on the way in: a session persisted
    # by a build before the `scrub/1` guard can carry an invalid UTF-8
    # byte in a tool result, which would make every request fail to
    # encode ("provider down"). Healing here also persists the fix.
    context =
      case Keyword.get(opts, :context) do
        nil ->
          Context.new()
          |> Context.append(ReqLLM.Context.system(system_prompt))

        %Context{} = restored ->
          sanitize_context(restored)
      end

    {:ok,
     State.new(
       id: id,
       context: context,
       model: model,
       status: status,
       scope_root: scope_root,
       policy: policy,
       pending_tool_calls: pending_tool_calls,
       pending_round_calls: pending_round_calls,
       pending_round_results: pending_round_results,
       # [providers.*] snapshot (layer 0 < global < project): consulted
       # per request (request_parts/1) and by the TUI's model menu
       # (provider_config_of/1). Found live NEVER SEEDED — every
       # session resolved against an empty registry, so non-native
       # providers (ollama_cloud via provider = "openai") failed closed
       # with :bad_entry and the model menu showed only the current
       # model.
       provider_config: snapshot.providers,
       # Sandbox mount schema (ADR 015): rw/ro/hide from the config
       # layers. `rw` may only come from shipped + global, so a repo
       # cannot widen its own sandbox.
       mounts: snapshot.mounts,
       # the resolved agent definition (ADR 017), or nil. The UI reads its
       # name/model for the two slots (ADR 018); the gate uses its policy
       # layer via state.policy.
       agent: agent,
       base_policy: base_policy,
       base_prompt: base_prompt,
       prompt_override: prompt_override,
       # resumed state carried forward: usage drives the compaction
       # trigger (see above), warned/backoff avoid re-warning and
       # re-retrying a summarize that already failed before the restart
       usage: usage,
       compaction_warned: compaction_warned,
       compaction_backoff: compaction_backoff,
       # the per-turn round budget resolved from config.toml (ADR 025);
       # an agent's max_turns overrides it per turn (State.tool_budget/1)
       max_tool_rounds: Config.max_tool_rounds(snapshot),
       # the session's reasoning effort (ADR 029), resolved from the same
       # layered config.toml; rides every request via wire_request/2.
       # A malformed value raises inside Config (loud, never a no-op).
       reasoning_effort: Config.reasoning_effort(snapshot),
       # the model window and the two compaction limits (ADR 037)
       context_window: window,
       compaction_soft_limit: soft_limit,
       compaction_hard_limit: hard_limit,
       context_window_source: window_source,
       # a driver that can answer a mid-turn question (the TUI sets this);
       # a headless driver gets the automatic wrap-up at the budget
       interactive: Keyword.get(opts, :interactive, false),
       # Subagent seams (ADR 017/018). A primary is depth 0; a delegated
       # child is depth 1 (no further delegation). The names a `task` call
       # may delegate to are resolved here so the tool can advertise them.
       depth: Keyword.get(opts, :depth, 0),
       subagents: delegatable_names(Config.agents(scope_root)),
       persist?: Keyword.get(opts, :persist?, true),
       # a resumed budget pause re-offers its dialog (the held round and
       # the question are durable)
       budget_pause: Keyword.get(opts, :budget_pause),
       # a resumed doom-loop pause re-offers too (ADR 026)
       doom_pause: Keyword.get(opts, :doom_pause),
       # a resumed question pause re-offers too (ADR 027)
       question_pause: Keyword.get(opts, :question_pause),
       # the model's todo list survives a resume (ADR 031)
       todos: Keyword.get(opts, :todos, []),
       test_mode: test_mode,
       turn_runner: turn_runner,
       subagent_runner: subagent_runner,
       idle_compaction_runner: idle_compaction_runner
     )}
  end

  # The names a `task` call may delegate to (ADR 017/018): `:subagent` and
  # `:all` definitions, never a `primary`. A broken definition set reads as
  # "nothing delegatable" here; the parent's own turn surfaces the load
  # error if it matters, and `Subagent.find_definition/2` reports it.
  defp delegatable_names({:ok, definitions}),
    do:
      definitions
      |> CodingAgent.Core.Session.Subagent.delegatable()
      |> Enum.map(&%{name: &1.name, description: &1.description})

  defp delegatable_names(_), do: []

  # Schedule the orphan-ref sweep (review N54) off the start path (review
  # N63). The start returns immediately; the git call runs in a supervised
  # task, so a cold/slow git never delays a session start. The keep-set
  # (every persisted id, every live id, plus THIS id, captured at schedule
  # time) is snapshotted in the task.
  defp schedule_checkpoint_reconcile(scope_root, id) do
    # `Task.start/1` links, so the whole body must be crash-proof: a raise
    # or exit here must never take the session down. `reconcile_checkpoints`
    # already rescues; this catch is the belt for an exit.
    Task.start(fn ->
      try do
        reconcile_checkpoints(scope_root, id)
      catch
        kind, reason ->
          Logger.debug("checkpoint reconcile task ended: #{inspect({kind, reason})}")
          :ok
      end
    end)
  end

  # Collect checkpoint refs whose session is gone (review N54). The keep
  # set is every persisted session id, every LIVE session id, and `id`.
  # Conservative: only refs in the attributable
  # `<store>/<session>/<commit>` form are candidates, so a legacy or
  # unattributable ref is never deleted.
  defp reconcile_checkpoints(scope_root, id) do
    known = [id | Store.ids()] ++ live_session_ids()
    _ = Checkpoint.reconcile(%{root: scope_root}, known)
    :ok
  rescue
    e ->
      Logger.debug("checkpoint reconcile skipped: #{Exception.message(e)}")
      :ok
  end

  defp live_session_ids do
    # Registry entries are {key, pid, value}; match the session keys.
    Registry.select(CodingAgent.Registry, [{{{:session, :"$1"}, :_, :_}, [], [:"$1"]}])
  rescue
    _ -> []
  end

  # Resolves the named agent definition and applies it. Returns
  # `{:ok, agent_or_nil, policy, system_prompt}` or `{:error, reason}`.
  #
  # A named agent that cannot be found (or a definition set that does not
  # load) is an error; the caller at init raises, the caller at set_agent
  # returns it. An absent name is the no-agent path.
  # Agent switches (Tab) are rare, so a fresh load per switch is fine
  # and keeps definitions live for the current process. (Only the
  # definitions are needed — not the whole config snapshot.)
  defp agents_of(state), do: Config.agents(state.scope_root)

  defp resolve_agent(nil, policy, system_prompt, _agents) do
    {:ok, nil, policy, system_prompt}
  end

  defp resolve_agent(name, policy, system_prompt, agents) when is_binary(name) do
    case agents do
      {:ok, definitions} ->
        case Enum.find(definitions, &(&1.name == name)) do
          nil ->
            {:error, {:unknown_agent, name, Enum.map(definitions, & &1.name)}}

          agent ->
            composed = Prompt.compose_agent(system_prompt, agent.prompt)
            {:ok, agent, Permissions.apply_agent(policy, agent), composed}
        end

      {:error, errors} ->
        {:error, {:bad_definitions, errors}}
    end
  end

  # A human-readable message for a resolve_agent error.
  defp format_agent_error({:unknown_agent, name, available}) do
    "unknown agent #{inspect(name)}; available: #{Enum.join(available, ", ")}"
  end

  defp format_agent_error({:bad_definitions, errors}) do
    "cannot load agent definitions:\n  " <> Enum.join(errors, "\n  ")
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, {:ok, state}, state}

  # /undo (ADR 036): a boundary verb. Refused mid-turn (the worker would
  # race the restore); otherwise restore the newest checkpoint, drop it,
  # and persist.
  def handle_call(:undo, _from, %{worker_ref: ref} = state) when is_reference(ref),
    do: {:reply, {:error, :busy}, state}

  def handle_call(:undo, _from, %{checkpoints: []} = state),
    do: {:reply, {:error, :nothing_to_undo}, state}

  def handle_call(:undo, _from, state) do
    [cp | rest] = Enum.reverse(state.checkpoints)

    case Checkpoint.restore(tool_scope(state), cp) do
      :ok ->
        state = %{state | checkpoints: Enum.reverse(rest)}
        persist(state)
        broadcast(state, {:info, "· undid the last checkpoint (files restored)"})
        {:reply, {:ok, length(state.checkpoints)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Manual `/compact` / ctrl-x c (ADR 037): summarize now regardless of
  # the limits. A boundary verb like /undo — only from an IDLE session,
  # so it cannot rewrite the context a parked gate/budget/doom round is
  # about to append to. The summary is slow, so it runs in the same
  # background slot as the idle soft pass (same fingerprint guard: a
  # context that changes under the summary is discarded, not clobbered).
  # `Compactor.can_compact?/1` reports false in test_mode, so that path
  # is :nothing, never a booked task with no provider.
  def handle_call(:compact, _from, %{status: status} = state) when status != :idle,
    do: {:reply, :turn_running, state}

  def handle_call(:compact, _from, %{idle_compaction_ref: ref} = state)
      when is_reference(ref),
      do: {:reply, :already_compacting, state}

  def handle_call(:compact, _from, state) do
    if Compactor.can_compact?(state) do
      fp = context_fingerprint(state)
      ref = spawn_compaction(state, :manual)

      {:reply, :started, %{state | idle_compaction_ref: ref, idle_compaction_fp: fp}}
    else
      {:reply, :nothing, state}
    end
  end

  def handle_call({:set_id, new_id}, _from, state) do
    {:reply, :ok, struct!(state, id: new_id)}
  end

  # model-menu switch: swap the wire model mid-session. The NEXT turn
  # resolves it (request_parts/1 splits state.model per call), so a
  # running session changes models at the boundary, not mid-stream.
  #
  # While a turn is in flight the switch is DEFERRED: the worker took a
  # snapshot at turn start and would otherwise clobber the switch when
  # its state merges back. It applies at the boundary.
  def handle_call({:set_model, model}, _from, %{worker_ref: ref} = state)
      when is_reference(ref) do
    {:reply, :ok, %{state | pending_model: model}}
  end

  def handle_call({:set_model, model}, _from, state) do
    # Persist like the idle `set_agent` path: a switch between turns is
    # durable state. Without it, quitting before the next turn lost the
    # switch and a resume came back on the OLD model (found live: "it
    # always resets to glm" — the menu showed deepseek, the resumed
    # session ran glm again).
    #
    # The framework prompt is model-selected (ADR 024), so a model switch
    # also recomposes the system prompt for the new model. The agent body
    # is re-composed on top so a switch does not drop the active role.
    new_state = state |> apply_model(model) |> recompose_prompt()
    persist(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:set_agent, name}, _from, %{worker_ref: ref} = state)
      when is_reference(ref) do
    # Resolve NOW so an unknown agent errors promptly (and nothing is
    # deferred), but apply at the turn boundary: a running turn keeps
    # the agent it started with (ADR 018).
    case resolve_agent(name, state.base_policy, state.base_prompt, agents_of(state)) do
      {:ok, agent, policy, prompt} ->
        {:reply, {:ok, state}, %{state | pending_agent: {:set, agent, policy, prompt}}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_agent, name}, _from, state) do
    # Recompute from the base values so switching does not compound; the
    # system message is replaced in place (index 0) when present. A
    # definition may pin its own `model` (ADR 017), which changes
    # `State.effective_model/1` and therefore the window/limits (ADR 037
    # OQ1, review N26) — recompute them like the model-switch paths do.
    case resolve_agent(name, state.base_policy, state.base_prompt, agents_of(state)) do
      {:ok, agent, policy, prompt} ->
        context = Prompt.replace_in_context(state.context, prompt)

        new_state =
          %{state | agent: agent, policy: policy, context: context} |> recompute_window()

        persist(new_state)
        {:reply, {:ok, new_state}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:subscribe, {pid, _}, state) do
    # registry registration happened in the caller (see subscribe/1);
    # the monitor lets the session drop dead subscribers
    monitor = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [monitor | state.subscribers]}}
  end

  # A turn is ALREADY in flight: queue instead of running inline. This
  # keeps the old mailbox serialization (one turn at a time, in arrival
  # order) while the session process itself stays responsive.
  def handle_call({:run, prompt}, from, %{worker_ref: ref} = state)
      when is_reference(ref) do
    {:noreply, %{state | queued_calls: state.queued_calls ++ [{:run, from, prompt}]}}
  end

  def handle_call({:run, prompt}, from, state) do
    {:noreply, start_run(state, from, prompt)}
  end

  def handle_call({:debug_gate, calls, opts}, _from, %{test_mode: true} = state) do
    # test_mode is REQUIRED, never set here: it used to be flipped true
    # unconditionally, so a live session that ever touched the hook
    # raised "test-mode session reached call_llm" on its next real turn.
    # Callers (all tests) already start the session with test_mode: true.
    rounds = Keyword.get(opts, :rounds, 0)
    state = %{state | status: :running, tool_rounds: rounds}
    {state, _result} = gate_tools(state, calls)
    {:reply, :ok, state}
  end

  def handle_call({:debug_gate, _calls, _opts}, _from, state) do
    {:reply, {:error, :not_test_mode}, state}
  end

  # ADR 010: driver decisions for interrupted (pending) tool calls.
  # decisions: list of maps %{id: call-id, decision: :approve | {:edit, args} | :reject}
  # The turn resumes only when every pending call has a decision.
  #
  # A turn already in flight (the gate can pause and the next round
  # stream) queues the decisions rather than blocking.
  def handle_call({:decide, decisions}, from, %{worker_ref: ref} = state)
      when is_reference(ref) do
    {:noreply, %{state | queued_calls: state.queued_calls ++ [{:decide, from, decisions}]}}
  end

  # A budget pause is also :interrupted but holds no pending TOOL calls;
  # refuse a decide here so the two pauses cannot be confused.
  def handle_call({:decide, _decisions}, _from, %{budget_pause: %{}} = state) do
    {:reply, {:error, {:budget_pause, :use_budget_decision}}, state}
  end

  # A doom-loop pause likewise is :interrupted with no pending TOOL calls.
  def handle_call({:decide, _decisions}, _from, %{doom_pause: %{}} = state) do
    {:reply, {:error, {:doom_pause, :use_doom_decision}}, state}
  end

  def handle_call({:decide, decisions}, from, %{status: :interrupted} = state) do
    case validate_decisions(state, decisions) do
      :ok ->
        if state.test_mode do
          # gate-mechanics tests stop here: no LLM round-trip
          {state, result} = run_decide_sync(state, decisions)
          {:reply, result, state}
        else
          {:noreply, start_decide(state, from, decisions)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:decide, _decisions}, _from, state) do
    {:reply, {:error, {:not_interrupted, state.status}}, state}
  end

  # ADR 025 budget prompt: continue (fresh budget, run the held round) or
  # stop (wrap up). Valid only while parked at the budget.
  def handle_call({:budget_decision, _decision}, _from, %{budget_pause: nil} = state) do
    {:reply, {:error, {:not_at_budget, state.status}}, state}
  end

  def handle_call({:budget_decision, :stop}, from, %{budget_pause: %{budget: budget}} = state) do
    # The held round is discarded (as in the non-interactive wrap-up); a
    # provider call follows, so it runs in a worker like every turn step.
    state = %{state | budget_pause: nil, status: :running}
    broadcast(state, {:status_changed, :running})
    persist(state)

    if state.test_mode do
      {state, _result} = wrap_up(state, budget)
      {:reply, {:ok, state}, state}
    else
      ref =
        spawn_turn(state, fn snapshot ->
          wrap_up(snapshot, budget)
        end)

      {:noreply, %{state | worker_ref: ref, worker_from: from}}
    end
  end

  def handle_call({:budget_decision, :continue}, from, %{budget_pause: %{calls: calls}} = state) do
    # A fresh full budget, and the held round runs. The round counter is
    # reset here (not in begin_run) so continuation does not accumulate.
    state = %{state | budget_pause: nil, status: :running, tool_rounds: 0}
    broadcast(state, {:status_changed, :running})
    persist(state)

    if state.test_mode do
      {state, _result} = run_round(state, calls)
      {:reply, {:ok, state}, state}
    else
      ref =
        spawn_turn(state, fn snapshot ->
          run_round(snapshot, calls)
        end)

      {:noreply, %{state | worker_ref: ref, worker_from: from}}
    end
  end

  # ADR 026 doom-loop prompt: continue (run the repeated round) or reject
  # (steer the model off the repetition). Valid only while parked.
  def handle_call({:doom_decision, _decision}, _from, %{doom_pause: nil} = state) do
    {:reply, {:error, {:not_at_doom, state.status}}, state}
  end

  def handle_call({:doom_decision, :continue}, from, %{doom_pause: %{calls: calls}} = state) do
    state = %{state | doom_pause: nil, status: :running}
    broadcast(state, {:status_changed, :running})
    persist(state)

    if state.test_mode do
      {state, _result} = run_round(state, calls)
      {:reply, {:ok, state}, state}
    else
      ref = spawn_turn(state, fn snapshot -> run_round(snapshot, calls) end)
      {:noreply, %{state | worker_ref: ref, worker_from: from}}
    end
  end

  def handle_call(
        {:doom_decision, :reject},
        from,
        %{doom_pause: %{calls: calls, tool: tool}} = state
      ) do
    state = %{state | doom_pause: nil, status: :running}
    broadcast(state, {:status_changed, :running})
    persist(state)

    reason =
      "repeated identical call rejected by the user — you called #{tool} with the " <>
        "same arguments #{@doom_loop_window} times; change approach or ask."

    if state.test_mode do
      {state, _result} = steer_round(state, calls, reason)
      {:reply, {:ok, state}, state}
    else
      ref = spawn_turn(state, fn snapshot -> steer_round(snapshot, calls, reason) end)
      {:noreply, %{state | worker_ref: ref, worker_from: from}}
    end
  end

  # ADR 027 question answer: run the held round with the question results
  # pre-known. One result per question call, in the order the calls
  # appeared.
  def handle_call({:answer_question, _answers}, _from, %{question_pause: nil} = state) do
    {:reply, {:error, {:not_at_question, state.status}}, state}
  end

  def handle_call(
        {:answer_question, answers},
        from,
        %{question_pause: %{calls: calls, questions: questions}} = state
      ) do
    state = %{state | question_pause: nil, status: :running}
    broadcast(state, {:status_changed, :running})
    persist(state)

    results = build_question_results(question_calls(calls), questions, answers)

    if state.test_mode do
      {state, _result} = execute_round(state, calls, results)
      {:reply, {:ok, state}, state}
    else
      ref = spawn_turn(state, fn snapshot -> execute_round(snapshot, calls, results) end)
      {:noreply, %{state | worker_ref: ref, worker_from: from}}
    end
  end

  # Build one tool result per question call. Each carries the formatted
  # answers (opencode's shape): `User has answered your questions:
  # "q"="a, b". You can now continue...`. An empty answer list renders as
  # `Unanswered`.
  defp build_question_results(calls, questions, answers) do
    formatted =
      questions
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {q, i} ->
        selected = Enum.at(answers, i) || []

        value =
          case selected do
            [] -> "Unanswered"
            list -> Enum.join(list, ", ")
          end

        ~s("#{q["question"]}"="#{value}")
      end)

    content =
      "User has answered your questions: #{formatted}. " <>
        "You can now continue with the user's answers in mind."

    Enum.map(calls, fn call ->
      {id, name, _args} = ToolCall.normalize(call)
      %{id: id, name: name, content: content}
    end)
  end

  # Every pending call needs a decision; partial answers are refused
  # (same contract as before, now checked before a worker is started so
  # the error is returned promptly).
  defp validate_decisions(state, decisions) do
    pending = state.pending_tool_calls
    by_id = Map.new(decisions, fn d -> {d.id, d.decision} end)

    missing =
      Enum.reject(pending, fn call ->
        {id, _, _} = ToolCall.normalize(call)
        Map.has_key?(by_id, id)
      end)

    if missing == [] do
      :ok
    else
      {:error,
       {:missing_decisions, Enum.map(missing, fn c -> elem(ToolCall.normalize(c), 0) end)}}
    end
  end

  defp resolve_decisions_for(state, decisions) do
    by_id = Map.new(decisions, fn d -> {d.id, d.decision} end)
    resolve_decisions(state, state.pending_tool_calls, by_id)
  end

  # test-mode decide: apply the decisions, go idle, no provider round
  # trip (gate-mechanics tests stop here by design).
  defp run_decide_sync(state, decisions) do
    state = state |> resolve_decisions_for(decisions) |> then(&%{&1 | status: :idle})
    state = persist(state)
    # broadcast the landed status: the same authority the async path has
    # (the TUI's reply handler is a no-op now; the broadcasts are what
    # move it — see the approval-reply note in the TUI).
    broadcast(state, {:status_changed, :idle})
    {state, {:ok, state}}
  end

  # Apply approve/edit/reject to every pending call; build tool-result
  # messages so the model sees the outcome. Approved/edited calls are
  # executed immediately; rejected calls get a rejection message.
  #
  # The round is completed as ONE canonical exchange (see complete_round):
  # the assistant message declares every application call of the round —
  # including the auto-executed and policy-denied ones carried in state
  # across the pause — in final (possibly edited) form.
  defp resolve_decisions(state, pending, by_id) do
    {to_run, decided_results, decided_calls} =
      Enum.reduce(pending, {[], [], %{}}, fn call, {run, results, calls} ->
        {id, name, _args} = ToolCall.normalize(call)
        decision = Map.fetch!(by_id, id)

        case decision do
          :approve ->
            {[call | run], results, Map.put(calls, id, call)}

          {:edit, new_args} ->
            edited = edit_call(call, new_args)
            {[edited | run], results, Map.put(calls, id, edited)}

          :reject ->
            result = %{id: id, name: name, content: "error: the user rejected this action"}
            {run, [result | results], Map.put(calls, id, call)}
        end
      end)

    to_run = Enum.reverse(to_run)
    decided_results = Enum.reverse(decided_results)

    executed_results = execute_tools(state, to_run)

    Enum.each(executed_results, fn r ->
      broadcast(state, {:tool_executed, r.name, r.content, Map.get(r, :arguments, %{})})
    end)

    # A session persisted before the round carry existed has no
    # pending_round_calls: fall back to the pending calls alone (still a
    # coherent exchange, just without the auto/denied halves).
    round_calls =
      if state.pending_round_calls == [], do: pending, else: state.pending_round_calls

    final_calls =
      Enum.map(round_calls, fn call ->
        {id, _, _} = ToolCall.normalize(call)
        Map.get(decided_calls, id, call)
      end)

    all_results = state.pending_round_results ++ decided_results ++ executed_results

    result_msgs =
      Enum.map(all_results, fn %{id: id, name: name, content: content} ->
        Context.tool_result_message(name, id, content)
      end)

    assistant_msg = assistant_message_for(final_calls)
    exchange = ReqLLM.Context.append_tool_exchange(state.context, assistant_msg, result_msgs)

    case exchange do
      {:ok, context} ->
        state = %{
          state
          | context: context,
            pending_tool_calls: [],
            pending_round_calls: [],
            pending_round_results: []
        }

        persist(state)
        state

      {:error, reason} ->
        Logger.error("tool exchange failed: #{inspect(reason)}")
        state
    end
  end

  defp assistant_message_for(calls) do
    tcalls =
      Enum.map(calls, fn call ->
        {id, name, args} = ToolCall.normalize(call)

        %ReqLLM.ToolCall{
          id: id,
          type: "function",
          function: %{name: name, arguments: args_json(args)}
        }
      end)

    %ReqLLM.Message{role: :assistant, content: [], tool_calls: tcalls}
  end

  # The assistant tool-call message goes back to the model, so it must
  # carry the args the model produced (or the user edited in). A
  # hardcoded "{}" here erased every prior call's arguments from the
  # model's view — the model then saw its own shell calls as empty and
  # re-emitted empty-args calls (live: 12-round loop of
  # "required :command option not found" — the "dropped command" bug).
  # `ToolCall.normalize/1` already decoded any JSON string to a map.
  defp args_json(args) when is_map(args), do: Jason.encode!(args)

  defp edit_call(%ReqLLM.ToolCall{} = call, new_args) do
    %{call | function: %{call.function | arguments: Jason.encode!(new_args)}}
  end

  defp edit_call(%{arguments: _} = call, new_args), do: %{call | arguments: new_args}

  # -- Prompt recomposition (ADR 024) -----------------------------------------

  # Apply a new model and, with it, the model-selected framework prompt.
  defp apply_model(state, model) do
    base_prompt = Prompt.base(system_prompt_override(state), state.scope_root, model)

    # A different model has a different window (ADR 037 OQ1, review N9):
    # re-resolve the compaction limits for the NEW effective model, so the
    # sidebar, the budget block and the next decision describe the model
    # that will actually run.
    %{state | model: model, base_prompt: base_prompt}
    |> recompute_window()
  end

  # Re-derive the system prompt from the (fresh) base + the current agent
  # body, and swap it into the context. Used after a model switch, which
  # changes `base_prompt` (ADR 024).
  defp recompose_prompt(%{agent: nil} = state) do
    maybe_replace_system(state, state.base_prompt)
  end

  defp recompose_prompt(%{agent: agent} = state) do
    composed = Prompt.compose_agent(state.base_prompt, agent.prompt)
    maybe_replace_system(state, composed)
  end

  defp system_prompt_override(state), do: state.prompt_override

  defp maybe_replace_system(state, prompt) do
    if is_binary(prompt) do
      %{state | context: Prompt.replace_in_context(state.context, prompt)}
    else
      state
    end
  end

  # Per-agent temperature (ADR 017/024): a definition may pin its own
  # sampling temperature. Absent, the provider default stands. req_llm
  # takes it as a request option (0.0-2.0).
  defp put_temperature(opts, %{temperature: t}) when is_number(t),
    do: Keyword.put(opts, :temperature, t)

  defp put_temperature(opts, _agent), do: opts

  # The session's reasoning effort (ADR 029): a canonical req_llm option.
  # Resolution already happened at init (Config.reasoning_effort/1); here
  # it only rides the wire. nil means "provider default", so no key at all
  # (an explicit nil would be a no-op key req_llm has to filter).
  defp put_reasoning_effort(opts, effort) when is_atom(effort) and not is_nil(effort),
    do: Keyword.put(opts, :reasoning_effort, effort)

  defp put_reasoning_effort(opts, _effort), do: opts

  @impl true
  # The turn worker RETURNED (async_nolink sends {ref, result} before the
  # DOWN): adopt the worker's final state and reply to the caller. This
  # clause MUST precede the generic DOWN clause below.
  def handle_info({ref, {new_state, result}}, %{worker_ref: ref} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_worker(state, new_state, result)}
  end

  # The turn worker CRASHED (provider stack, a bug in the loop, or a
  # kill): turn it into a failed turn so the :infinity caller is never
  # left hanging. The worker's in-progress state is lost, but the last
  # persisted boundary survives; the session just goes to :error.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worker_ref: ref} = state)
      when is_reference(ref) do
    Logger.error("turn worker crashed: #{inspect(reason)}")
    state = fail_turn(state, {:turn_worker_exit, reason})
    {:noreply, finish_worker(state, state, {:error, {:turn_worker_exit, reason}})}
  end

  # A BACKGROUND compaction task returned: the IDLE (soft-limit) pass or a
  # manual `/compact`. Apply only when the context is UNCHANGED since the
  # task started (fingerprint match) — otherwise a new turn/compaction
  # began while the summary ran and the result is stale. Never reply or
  # broadcast idle: the session was already idle.
  def handle_info({ref, {new_state, _changed?}}, %{idle_compaction_ref: ref} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_compaction_result(state, new_state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{idle_compaction_ref: ref} = state)
      when is_reference(ref) do
    # the compaction task crashed/shut down: drop the handles, keep the
    # context (the hard, pre-call pass still guards the window)
    {:noreply, %{state | idle_compaction_ref: nil, idle_compaction_fp: nil}}
  end

  # A subscribed process died: drop its monitor.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, monitor)}}
  end

  # The model catalog finished loading (ADR 039). Re-resolve the window if
  # it was provisional (no configured `context_window`): before the warm,
  # a cataloged model resolved to the fallback, so its limits were wrong.
  # Recompute and broadcast so the sidebar (which mirrors the values) and
  # the next compaction decision use the real numbers. Idempotent.
  def handle_info({:catalog, :updated}, state) do
    {:noreply, refresh_catalog_window(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Re-resolve the window/limits against the now-loaded catalog. A
  # configured window never listens (it always wins), but re-resolving is
  # harmless; we skip the broadcast when nothing changed.
  defp refresh_catalog_window(state), do: recompute_window(state)

  # Re-resolve the compaction window/limits for the state's CURRENT
  # effective model (ADR 037 OQ1, review N9) and broadcast when they
  # change, so the sidebar, the budget block and the next decision stay
  # consistent. Called after a catalog warm AND after a model/agent switch
  # (the switch is what made "resolved once at init" visibly wrong: the
  # session kept the old model's window, and the provider could then reject
  # a context the budget thought fit — or vice versa).
  defp recompute_window(state) do
    snapshot = Config.snapshot(state.scope_root)

    {{window, soft, hard}, source} =
      Config.compaction_limits_resolved(snapshot, State.effective_model(state))

    state = maybe_warn_unverified_window(state, source, window)

    if {window, soft, hard} ==
         {state.context_window, state.compaction_soft_limit, state.compaction_hard_limit} do
      %{state | context_window_source: source}
    else
      Events.publish(state.id, {:context_window, window, soft, hard})

      %{
        state
        | context_window: window,
          compaction_soft_limit: soft,
          compaction_hard_limit: hard,
          context_window_source: source
      }
    end
  end

  # The window fell back to the default because the catalog is loaded but
  # does NOT know the model (review: the owner's "the compact window is too
  # big to compact" — `ollama_cloud:*` is uncataloged, so a 500k window and
  # a 250k soft limit were assumed). Log ONCE per session, actionable: name
  # the model, the assumed window and how to set the real one. A LOG, not a
  # transcript note: the always-visible cue is the sidebar's "(assumed)"
  # marker, and a note on every fresh uncataloged session would be noise.
  # `:loading` is silent — it is provisional and self-heals on the
  # catalog-ready re-resolve.
  defp maybe_warn_unverified_window(%{window_warned: true} = state, :fallback, _window), do: state

  # a test-mode session is structurally provider-free: no log noise (the
  # suite runs many sessions against uncataloged test models)
  defp maybe_warn_unverified_window(%{test_mode: true} = state, :fallback, _window), do: state

  defp maybe_warn_unverified_window(state, :fallback, window) when is_integer(window) do
    Logger.warning(
      "context window for #{State.effective_model(state)} is unknown to the model " <>
        "catalog; assuming #{div(window, 1000)}k tokens. If the model's real window is " <>
        "smaller, set `context_window` in config.toml — otherwise compaction fires too " <>
        "late to be useful."
    )

    %{state | window_warned: true}
  end

  defp maybe_warn_unverified_window(state, _source, _window), do: state

  # -- The loop ---------------------------------------------------------------

  # -- Turn workers (the session stays responsive while a turn streams) -------
  #
  # The blocking loop (provider streaming, tools, compaction) runs in a
  # supervised `async_nolink` task, NOT in the session process. The
  # session holds the durable state and only routes: it starts a worker,
  # keeps answering calls, and merges the worker's final state when it
  # reports back. See `TurnTaskSupervisor`.

  # Prepare and launch the run worker. Returns the updated session state
  # with the worker booked (worker_ref/worker_from set).
  defp start_run(state, from, prompt) do
    # Re-resolve the window on the first real turn: at init the catalog may
    # still be warming (`:loading`), so an uncataloged model's window is only
    # known (as `:fallback`) once loaded. This also emits the once-per-session
    # "unverified window" note before the first request, so the model's budget
    # block and the warning agree. Idempotent and cheap when unchanged. Skips
    # a test-mode session: the warning is a real-provider concern, and an
    # injected note would perturb the display the suite asserts on.
    state = if state.test_mode, do: state, else: recompute_window(state)
    state = begin_run(state, prompt)
    runner = state.turn_runner

    ref =
      spawn_turn(state, fn snapshot ->
        case runner do
          nil -> continue_loop(snapshot)
          fun -> fun.(snapshot)
        end
      end)

    %{state | worker_ref: ref, worker_from: from}
  end

  # Resume a parked turn after decisions. The decisions are applied and
  # the loop continued in the worker (same reasoning as start_run).
  defp start_decide(state, from, decisions) do
    runner = state.turn_runner

    ref =
      spawn_turn(state, fn snapshot ->
        state = resolve_decisions_for(snapshot, decisions)

        case runner do
          nil -> continue_loop(state)
          fun -> fun.(state)
        end
      end)

    %{state | worker_ref: ref, worker_from: from}
  end

  # The blocking prep that must be visible to `state/1` immediately:
  # append the user message, flip to :running, reset the per-turn guard,
  # record the turn's agent, announce the turn.
  defp begin_run(state, prompt) do
    context = state.context |> Context.append(ReqLLM.Context.user(prompt))

    # Record WHICH agent answers this user turn (ADR 018 attribution):
    # the per-turn agent the loop is about to resolve. Synthetic user
    # messages (compaction summaries) never reach begin_run — they are
    # added by the Compactor, not by the user — so turn_agents stays
    # aligned with real turns, one entry per user prompt.
    agent = if state.agent, do: state.agent.name, else: nil

    # Checkpoint the worktree before the turn can write anything (ADR
    # 036). Runs in the SESSION process (synchronous), before the worker
    # starts: a snapshot taken any later could already contain the turn's
    # own edits. A read-only or non-git scope is a no-op.
    state = take_checkpoint(state)

    # A new turn invalidates any in-flight background compaction (idle
    # soft pass or manual /compact): its result would be for a context
    # that no longer matches (the fingerprint check in
    # apply_compaction_result discards it anyway), so drop the
    # monitor here and forget it. The task itself is harmless: async_nolink
    # and supervised, its messages simply no longer match a clause.
    state =
      case state.idle_compaction_ref do
        ref when is_reference(ref) ->
          Process.demonitor(ref, [:flush])
          %{state | idle_compaction_ref: nil, idle_compaction_fp: nil}

        _ ->
          state
      end

    # the loop guard is PER TURN: the counter previously only reset in
    # the debug path, so it accumulated across a session's lifetime —
    # found live: the review session died at the 25-round limit after
    # several healthy turns (each turn's rounds stack on the old count)
    state =
      %{
        state
        | context: context,
          status: :running,
          last_error: nil,
          tool_rounds: 0,
          # the doom-loop window is per turn (ADR 026)
          recent_calls: [],
          turn_agents: state.turn_agents ++ [agent]
      }

    # the display view records the user prompt (ADR 020); the agent view
    # already has it in the context
    _ = Store.append_display(state.id, :user, prompt, agent: agent)

    broadcast(state, {:turn_started, agent})
    broadcast(state, {:status_changed, :running})
    state
  end

  # -- File checkpoints (ADR 036) ---------------------------------------------

  # Snapshot the worktree before a turn and keep the newest
  # `checkpoint_depth` checkpoints. Best effort: a snapshot failure must
  # never block the turn (the human can always fall back to git); it is
  # logged, not raised.
  defp take_checkpoint(state) do
    depth = Config.checkpoint_depth(state.scope_root)

    cond do
      depth == 0 or state.test_mode or state.depth > 0 ->
        state

      true ->
        case Checkpoint.snapshot(tool_scope(state), state.id) do
          {:ok, cp} ->
            kept = Enum.take(state.checkpoints ++ [cp], -depth)
            dropped = (state.checkpoints ++ [cp]) |> Enum.drop(-depth)
            Enum.each(dropped, &Checkpoint.drop(tool_scope(state), &1))
            %{state | checkpoints: kept}

          :skip ->
            state

          {:error, reason} ->
            Logger.warning("checkpoint failed for #{state.id}: #{inspect(reason)}")
            warn_checkpoint_failure(state, reason)
        end
    end
  end

  # A checkpoint that failed must not stay invisible (review F3): otherwise
  # the human assumes `/undo` works. Surface it ONCE per session as a
  # transcript note (the transcript line is the durable, visible signal;
  # the Logger line above is the diagnostic).
  defp warn_checkpoint_failure(%{checkpoint_warned: true} = state, _reason), do: state

  defp warn_checkpoint_failure(state, reason) do
    broadcast(
      state,
      {:info,
       "· checkpoint failed — /undo will not restore this turn: #{checkpoint_reason(reason)}"}
    )

    %{state | checkpoint_warned: true}
  end

  # A short, human-readable cause; the full error is in the log. The git
  # steps fail as `{tag, code, output}`, so surface the first output line.
  defp checkpoint_reason({_tag, _code, out}) when is_binary(out) and out != "",
    do: out |> String.split("\n", trim: true) |> List.first() |> String.trim()

  defp checkpoint_reason(other), do: inspect(other)

  # Starts the worker under the turn supervisor and returns the monitor
  # ref. The worker gets a snapshot with the session's runtime
  # bookkeeping stripped (it must never persist a stale worker ref, and
  # it must not carry the queue/pending switches the SESSION owns while
  # the turn runs).
  defp spawn_turn(state, fun) do
    snapshot = worker_snapshot(state)
    task = Task.Supervisor.async_nolink(task_supervisor(), fn -> fun.(snapshot) end)
    task.ref
  end

  defp task_supervisor do
    case Process.whereis(CodingAgent.Core.Session.TurnTaskSupervisor) do
      nil ->
        # bare tests without the app tree: lazy, like the compactor's
        case CodingAgent.Core.Session.TurnTaskSupervisor.start_link() do
          {:ok, _pid} -> CodingAgent.Core.Session.TurnTaskSupervisor
          {:error, {:already_started, _pid}} -> CodingAgent.Core.Session.TurnTaskSupervisor
        end

      pid when is_pid(pid) ->
        pid
    end
  end

  # Runtime fields are process-local to the SESSION; the worker snapshot
  # carries only durable content plus the test seams. subscribers are
  # cleared too: they are live monitor refs, not data — the worker must
  # never persist its stale copy (and it broadcasts via the Registry,
  # not this list).
  #
  # `subagent_runner` stays IN the worker snapshot (unlike `turn_runner`,
  # which the spawn closure captures directly): `Subagent.run/2` reads it
  # from the worker's state to build the child's blocking body. Both are
  # stripped before any disk write (see `strip_runner/1`).
  defp worker_snapshot(state) do
    %{
      state
      | worker_ref: nil,
        worker_from: nil,
        queued_calls: [],
        pending_agent: :none,
        pending_model: :none,
        subscribers: [],
        # an idle-compaction task is process-local too; a worker snapshot
        # must never carry its ref (the result is adopted by the SESSION,
        # not the worker)
        idle_compaction_ref: nil,
        idle_compaction_fp: nil,
        # the runner is captured in the worker closure, not the snapshot:
        # a closure must never be persisted
        turn_runner: nil
    }
  end

  # The worker completed (returned or crashed): adopt its final state,
  # apply any switch the SESSION deferred during the turn, reply to the
  # original caller, and run the next queued call.
  defp finish_worker(session, new_state, reply) do
    switched? = session.pending_agent != :none or session.pending_model != :none

    new_state =
      %{
        new_state
        | # the SESSION owns these while a turn runs: adopt the durable
          # result but keep the live subscriber list / id and the queue
          subscribers: session.subscribers,
          id: session.id,
          turn_runner: session.turn_runner,
          subagent_runner: session.subagent_runner,
          worker_ref: nil,
          worker_from: nil,
          queued_calls: session.queued_calls,
          pending_agent: :none,
          pending_model: :none
      }
      |> apply_pending_switches(session)

    # a switch applied at the boundary is part of the durable state, like
    # the idle set_agent/2 path (otherwise a restart loses it)
    if switched?, do: persist(new_state)

    if session.worker_from, do: GenServer.reply(session.worker_from, reply)
    drain_queue(start_idle_compaction_then_drain(new_state))
  end

  # The idle soft pass must be spawned by the SESSION process (the task
  # ref is booked on the session state), not by the turn worker. A queued
  # run takes priority: drain first, and only start the background pass
  # when nothing is waiting.
  defp start_idle_compaction_then_drain(%{queued_calls: []} = state),
    do: start_idle_compaction(state)

  defp start_idle_compaction_then_drain(state), do: state

  # A mid-turn set_agent/set_model applied at the turn boundary. Agent
  # switches recompute from the base values (no compounding) and replace
  # the system prompt in place.
  defp apply_pending_switches(state, session) do
    # Agent first: its prompt was resolved from the OLD base_prompt, so it
    # must not run after the model recomposition (which would drop it).
    state =
      case session.pending_agent do
        :none ->
          state

        {:set, agent, policy, prompt} ->
          context = Prompt.replace_in_context(state.context, prompt)
          %{state | agent: agent, policy: policy, context: context}
      end

    # Then the model: a model switch swaps the model-selected framework
    # prompt (ADR 024) and re-applies the just-set agent body on top.
    state =
      case session.pending_model do
        :none -> state
        model -> state |> apply_model(model) |> recompose_prompt()
      end

    # The agent may pin its own model (ADR 017), so either switch can change
    # the effective model — and with it the window (review N9). Re-resolve
    # once, after both are applied, for the state that will actually run.
    recompute_window(state)
  end

  # One turn at a time, in arrival order: after a worker finishes, run
  # the next call that queued while it streamed.
  defp drain_queue(%{queued_calls: []} = state), do: state

  defp drain_queue(%{queued_calls: [{:run, from, prompt} | rest]} = state) do
    state = %{state | queued_calls: rest}
    start_run(state, from, prompt)
  end

  defp drain_queue(%{queued_calls: [{:decide, from, decisions} | rest]} = state) do
    state = %{state | queued_calls: rest}

    # the same gate as the direct handle_call clause: decisions only make
    # sense while the turn is parked at the approval gate. A queued
    # decide whose turn already ended idle is refused, not run.
    with :interrupted <- state.status,
         :ok <- validate_decisions(state, decisions) do
      if state.test_mode do
        {state, result} = run_decide_sync(state, decisions)
        GenServer.reply(from, result)
        drain_queue(state)
      else
        start_decide(state, from, decisions)
      end
    else
      {:error, reason} ->
        GenServer.reply(from, {:error, reason})
        drain_queue(state)

      other_status ->
        GenServer.reply(from, {:error, {:not_interrupted, other_status}})
        drain_queue(state)
    end
  end

  defp continue_loop(state) do
    # structural backstop for the tests-are-LLM-free discipline: a
    # test-mode session must never reach the provider, no matter what
    # code path leads here. Loud on purpose — a silent skip would let
    # a regression hide.
    if state.test_mode do
      raise "test-mode session #{state.id} reached call_llm — tests must be LLM-free"
    end

    # Loop boundary: a stop requested during an uninterruptible step
    # (compaction summarize, a long tool round) is honored here before
    # another provider call starts. There is no streamed text at this
    # point — end the turn idle (no empty assistant message on the wire)
    # and tell the transcript why.
    if Interrupt.requested?(state.id) do
      state = state |> drop_interrupt() |> stop_at_boundary()
      {state, {:ok, state}}
    else
      {state, changed?} = Compactor.maybe_compact(state)
      if changed?, do: persist(state)

      case call_llm(state) do
        {:ok, %{type: :final_answer, text: text, blocks: blocks, usage: usage}} ->
          state = state |> add_usage(usage) |> drop_interrupt() |> complete_turn(text, blocks)
          {state, {:ok, state}}

        {:ok, %{type: :tool_calls, tool_calls: calls, blocks: blocks, usage: usage}} ->
          state = state |> add_usage(usage) |> drop_interrupt() |> record_display_blocks(blocks)
          gate_tools(state, calls)

        # user stop (Interrupt.request/1): the partial text streamed so
        # far becomes the turn's answer (opencode esc parity — nothing
        # lost, the model can be nudged on from there), or, with no text,
        # a boundary-like stop with a note. See `interrupted_turn/2`.
        {:interrupted, partial} ->
          state = interrupted_turn(state, partial)
          {state, {:ok, state}}

        {:error, reason} ->
          state = state |> drop_interrupt() |> fail_turn(reason)
          {state, {:error, reason}}
      end
    end
  end

  # Turn end for a boundary stop: no streamed text exists, so there is
  # nothing to keep — just go idle and surface a transcript note.
  defp stop_at_boundary(state) do
    state = %{state | status: :idle}
    broadcast(state, {:info, "· turn stopped (esc)"})
    broadcast(state, {:status_changed, :idle})
    persist(state)
    state
  end

  # A stop that arrived mid-stream. With partial TEXT, that text is the
  # turn's answer (opencode esc parity — nothing lost). With NO text — a
  # stop during reasoning, or before the first delta — an answer would be
  # empty: `complete_turn("", [])` appended an empty assistant message and
  # broadcast an empty `llm_message`, so the turn ended with no visible
  # word and looked like the agent had "just stopped working" (found live).
  # Fall through to the same boundary end the between-rounds stop uses.
  #
  # The guard is `String.trim/1`-based (review N36): whitespace-only
  # deltas (`"\n  "`) are not an answer either, and `complete_turn` would
  # append a message whose display row `append_display/4` drops
  # (trim-empty), reproducing the silent end one level down.
  @doc false
  @spec interrupted_turn(State.t(), String.t()) :: State.t()
  def interrupted_turn(state, partial) do
    if String.trim(partial || "") == "" do
      state |> drop_interrupt() |> stop_at_boundary()
    else
      state |> drop_interrupt() |> complete_turn(partial, [])
    end
  end

  # The permission checkpoint (ADR 010): read-only tools pass by policy
  # (allow class defaults); state-changing tools get the effective
  # decision. :ask pauses the session (:interrupted) until the driver
  # supplies decisions for every pending call via decide/3.
  #
  # Guards run before the policy gate, in order:
  #
  #   * the tool-round budget (ADR 025): an INTERACTIVE driver is asked
  #     continue/stop; a driver that cannot answer gets the wrap-up;
  #   * the doom-loop guard (ADR 026): three consecutive identical ROUNDS
  #     pause an interactive driver (continue/reject); a non-interactive
  #     driver is steered silently.
  #
  # A `question` call is intercepted inside `run_round` (ADR 027): it is
  # answered by the human, not executed.
  defp gate_tools(state, calls) do
    state = remember_calls(state, calls)
    budget = tool_budget(state)

    cond do
      state.tool_rounds >= budget and state.interactive ->
        pause_at_budget(state, calls, budget)

      state.tool_rounds >= budget ->
        wrap_up(state, budget)

      doom_loop?(state) and state.interactive ->
        pause_at_doom(state, calls)

      doom_loop?(state) ->
        steer_doom(state, calls)

      true ->
        run_round(state, calls)
    end
  end

  # -- Doom-loop guard (ADR 026) ----------------------------------------------

  # Append THIS ROUND's call signature to the per-turn window, newest
  # last, capped at the window size. The window is over ROUNDS, not
  # individual calls: a doom loop is the model re-emitting the same call
  # across rounds (the "five minutes in circles" failure), not three
  # parallel identical calls in one intent. opencode checks per stream
  # part, which would also trip on the latter; we deliberately do not
  # (recorded in the ADR).
  #
  # A round's signature is its sorted list of {name, args} — so a round is
  # "the same" when it asked for the same calls, regardless of order.
  defp remember_calls(state, calls) do
    sig =
      calls
      |> Enum.map(fn call ->
        {_id, name, args} = ToolCall.normalize(call)
        {name, args}
      end)
      |> Enum.sort()

    window = Enum.take(state.recent_calls ++ [sig], -@doom_loop_window)
    %{state | recent_calls: window}
  end

  # True when the window is full and every ROUND is identical.
  defp doom_loop?(%{recent_calls: window}) do
    length(window) == @doom_loop_window and match?([x, x, x], window)
  end

  # Park at a detected loop (ADR 026). The round is held, so "continue"
  # runs exactly it and "reject" steers the model off the repetition.
  defp pause_at_doom(state, calls) do
    {_id, tool, _args} = ToolCall.normalize(hd(calls))

    broadcast(
      state,
      {:info, "· repeated call detected: #{tool} ×#{@doom_loop_window} — continue or reject"}
    )

    state = %{state | status: :interrupted, doom_pause: %{calls: calls, tool: tool}}
    broadcast(state, {:status_changed, :doom_reached, %{tool: tool}})
    persist(state)
    {state, {:ok, state}}
  end

  # Non-interactive fallback: steer silently. The held round is answered
  # with a synthetic tool result explaining the repetition, so the model
  # reads it (like a failed tool) and changes approach; the loop then
  # continues. No dialog, no hang.
  defp steer_doom(state, calls) do
    {_id, tool, _args} = ToolCall.normalize(hd(calls))
    Logger.warning("doom loop steered (non-interactive): #{tool}")

    steer_round(
      state,
      calls,
      "repeated identical call rejected — you have called #{tool} with the same " <>
        "arguments #{@doom_loop_window} times in a row; repeating will not help. " <>
        "Change approach or ask the user."
    )
  end

  # Answer every held call with a synthetic result carrying `reason`, then
  # complete the round and let the loop continue. Used by the silent steer
  # and by a user "reject".
  defp steer_round(state, calls, reason) do
    results =
      Enum.map(calls, fn call ->
        {id, name, _args} = ToolCall.normalize(call)
        %{id: id, name: name, content: "error: #{reason}"}
      end)

    broadcast_tools(state, calls, results)
    state = complete_round(state, calls, results)
    finish_round(state)
  end

  # Park the turn at the budget and ask the driver to continue or stop.
  # The round's calls are held (not executed, not on the wire) so
  # "continue" can run exactly this round under a fresh budget.
  defp pause_at_budget(state, calls, budget) do
    Logger.warning("tool-round budget reached: #{budget} (asking)")
    broadcast(state, {:info, "· turn budget reached (#{budget} rounds)"})

    state = %{
      state
      | status: :interrupted,
        budget_pause: %{calls: calls, budget: budget}
    }

    broadcast(state, {:status_changed, :budget_reached, %{budget: budget}})
    persist(state)
    {state, {:ok, state}}
  end

  defp run_round(state, calls) do
    state = %{state | tool_rounds: state.tool_rounds + 1}

    # A question is answered by the human, not executed (ADR 027). The
    # WHOLE round is held so the exchange stays atomic: any sibling calls
    # run only once the answer arrives.
    case question_calls(calls) do
      [] ->
        execute_round(state, calls)

      questions ->
        ask_question(state, calls, questions)
    end
  end

  # -- Question tool (ADR 027) -------------------------------------------------

  # The question calls in a round (usually zero or one), with their parsed
  # questions. Splitting here keeps `execute_round` free of the branch.
  defp question_calls(calls) do
    Enum.filter(calls, fn call ->
      {_id, name, _args} = ToolCall.normalize(call)
      name == Question.name()
    end)
  end

  # Park on the human's answer. The questions are parsed up front so a
  # malformed call is a result the model can fix, not a crash.
  #
  # A non-interactive driver cannot answer: the question is answered
  # synthetically ("the human is not available") and the round runs, so
  # the turn never hangs (the ADR 025/026 rule).
  defp ask_question(state, calls, [call | _] = q_calls) do
    {id, _name, args} = ToolCall.normalize(call)

    case parse_questions(args) do
      {:ok, questions} ->
        if state.interactive do
          broadcast(state, {:info, "· the agent asked a question"})

          state = %{
            state
            | status: :interrupted,
              question_pause: %{calls: calls, questions: questions}
          }

          broadcast(state, {:status_changed, :question_asked, %{questions: questions}})
          persist(state)
          {state, {:ok, state}}
        else
          Logger.warning("question asked with no interactive driver; answering unavailable")
          results = unavailable_question_results(q_calls)
          execute_round(state, calls, results)
        end

      {:error, reason} ->
        # a malformed question never pauses: answer it in-round so the
        # model can correct the schema and continue.
        result = %{id: id, name: Question.name(), content: "error: #{reason}"}
        broadcast_tools(state, [call], [result])
        state = complete_round(state, calls, [result])
        finish_round(state)
    end
  end

  # The synthetic answer when no human is available (ADR 027).
  defp unavailable_question_results(calls) do
    content =
      "error: the human is not available to answer questions right now. " <>
        "Proceed with your best judgment, or stop and state the question plainly in your answer."

    Enum.map(calls, fn call ->
      {id, name, _args} = ToolCall.normalize(call)
      %{id: id, name: name, content: content}
    end)
  end

  # Parses the tool arguments into a normalized question list. Lenient
  # about string/atom keys (tool args arrive as maps with string keys).
  defp parse_questions(args) do
    raw = Map.get(args, "questions") || Map.get(args, :questions)

    cond do
      not is_list(raw) or raw == [] ->
        {:error, "`questions` must be a non-empty array"}

      true ->
        questions =
          Enum.map(raw, fn q ->
            %{
              "question" => q["question"] || q[:question] || "",
              "header" => q["header"] || q[:header],
              "multiple" => q["multiple"] || q[:multiple] || false,
              "options" => normalize_options(q["options"] || q[:options] || [])
            }
          end)

        {:ok, questions}
    end
  end

  defp normalize_options(options) do
    Enum.map(options, fn o ->
      %{
        "label" => o["label"] || o[:label] || "",
        "description" => o["description"] || o[:description]
      }
    end)
  end

  # All gate policy lives in Session.Gate: it buckets this round's calls
  # (blacklist / escalation-without-reason / explicit deny / allow / ask)
  # using the one Permissions.effective/4 path. A `question` call never
  # reaches the policy gate (see run_round): it is answered by the human.
  #
  # `answered` carries question results already obtained (ADR 027) so a
  # resumed question round completes with them alongside the siblings'.
  defp execute_round(state, calls, answered \\ []) do
    q_calls = question_calls(calls)
    t_calls = task_calls(calls)
    d_calls = todo_calls(calls)
    c_calls = compact_calls(state, calls)

    answerable =
      Enum.reject(calls, &(&1 in q_calls or &1 in t_calls or &1 in d_calls or &1 in c_calls))

    # A `todowrite` call mutates session state, not the filesystem, and
    # never parks (ADR 031). Apply it up front so the round's sibling
    # calls and the next request see the new list.
    {state, todo_results} = apply_todos(state, d_calls)

    # A `compact` call (ADR 040 OQ1) shrinks the context NOW, mid-turn,
    # ignoring the thresholds — the model decided it wants headroom (the
    # same verb the human has via `/compact`). Apply it before the round's
    # request is built so siblings and the next call see the smaller
    # context. Like `todowrite` it never parks and has no filesystem
    # effect.
    {state, compact_results} = apply_compact(state, c_calls)

    plan = Gate.classify(state.id, state.policy, state.scope_root, answerable)

    blacklist_results =
      Enum.map(plan.blacklisted, fn call ->
        log_refusal(call, "gate: shell command denied (blacklist)")
        Gate.blacklist_result(call)
      end)

    no_reason_results =
      Enum.map(plan.no_reason, fn call ->
        log_refusal(call, "gate: shell escalation without reason refused")
        Gate.no_reason_result(call)
      end)

    # Results already decided for this round, before any human input, plus
    # the question answers and the todo updates.
    known_calls = plan.blacklisted ++ plan.no_reason ++ plan.denied

    known_results =
      answered ++
        todo_results ++
        compact_results ++
        blacklist_results ++
        no_reason_results ++ Enum.map(plan.denied, &Gate.denied_result/1)

    # A `task` call runs its child session inline (ADR 017/018): its only
    # trace in the parent context is the returned summary. Computed here
    # (not inside a branch) because the round is atomic — whether or not a
    # SIBLING call parks at the gate, every call needs exactly one result.
    task_results = run_subagents(state, t_calls)

    cond do
      # A SUBAGENT (depth > 0) has no human channel (ADR 017): it runs
      # inside a `task` call, so parking at the gate would hang the parent
      # turn forever. Fail closed — the pending calls get a denial the
      # model can read and adapt to. Escalations are declared in the
      # subagent's definition, never requested at runtime. A depth-0
      # headless driver keeps the usual park/decide contract.
      plan.pending != [] and state.depth > 0 ->
        auto_results = execute_tools(state, plan.auto)
        denied = Enum.map(plan.pending, &subagent_no_human_result/1)

        results = known_results ++ task_results ++ auto_results ++ denied

        broadcast_tools(
          state,
          known_calls ++ t_calls ++ plan.auto ++ plan.pending ++ q_calls ++ d_calls ++ c_calls,
          results
        )

        state = complete_round(state, calls, results)
        finish_round(state)

      plan.pending == [] ->
        auto_results = execute_tools(state, plan.auto)
        results = known_results ++ task_results ++ auto_results

        broadcast_tools(
          state,
          known_calls ++ t_calls ++ plan.auto ++ q_calls ++ d_calls ++ c_calls,
          results
        )

        state = complete_round(state, calls, results)
        finish_round(state)

      true ->
        # SOME call needs a human. The exchange is appended atomically
        # only once the whole round is decided, so nothing half-formed
        # ever reaches the wire. The auto/denied/question/task/todo
        # results computed now are carried in state across the pause (and
        # a resume).
        auto_results = execute_tools(state, plan.auto)

        state = %{
          state
          | status: :interrupted,
            pending_tool_calls: plan.pending,
            pending_round_calls: calls,
            pending_round_results: known_results ++ task_results ++ auto_results
        }

        broadcast_tools(
          state,
          known_calls ++ t_calls ++ plan.auto ++ d_calls ++ c_calls,
          known_results ++ task_results ++ auto_results
        )

        broadcast(state, {:status_changed, :interrupted, plan.pending})
        persist(state)
        {state, {:ok, state}}
    end
  end

  # The `todowrite` calls in a round (ADR 031). Like `question`/`task`,
  # they are intercepted before the gate: they mutate session state, not
  # the filesystem, and never park.
  defp todo_calls(calls) do
    Enum.filter(calls, fn call ->
      {_id, name, _args} = ToolCall.normalize(call)
      name == CodingAgent.Core.Tools.TodoWrite.name()
    end)
  end

  # The `compact` calls in a round (ADR 040 OQ1). Intercepted before the
  # gate, like `todowrite`: pure session-state mutation (the context
  # shrinks), no filesystem effect, never parks.
  #
  # Unlike `todowrite`, `compact` spends provider time and discards
  # context, so it must respect the toolset a policy/agent actually
  # ADVERTISES (review N45). The gate never sees it (intercepted first),
  # and `ToolRunner.tools/2`'s narrowing (`[tools] enabled`, an agent's
  # `disallowedTools`) only filters what is advertised — so without this
  # guard an agent that disabled `compact` could still call it. A call
  # that reaches here but is NOT in the exposed set falls through to the
  # gate as an unknown tool (denied), the same as any other.
  defp compact_calls(state, calls) do
    if compact_exposed?(state) do
      Enum.filter(calls, fn call ->
        {_id, name, _args} = ToolCall.normalize(call)
        name == CodingAgent.Core.Tools.Compact.name()
      end)
    else
      []
    end
  end

  defp compact_exposed?(state) do
    Enum.any?(current_tools(state), &(&1.name == CodingAgent.Core.Tools.Compact.name()))
  end

  # Runs the model's own compaction, synchronously, in the turn worker.
  # `Compactor.compact_now/2` ignores the soft/hard thresholds (the model
  # asked — "is it over a line?" is the wrong question, exactly like the
  # human's `/compact`). It blocks the worker on the summarize call, which
  # is the whole point: the round's siblings and the NEXT request must see
  # the smaller context, and the model gets a result describing what
  # happened. `test_mode` short-circuits (a clean `{state, false}`).
  defp apply_compact(state, []), do: {state, []}

  defp apply_compact(state, c_calls) do
    {state, results} =
      Enum.reduce(c_calls, {state, []}, fn call, {state, acc} ->
        {id, _name, _args} = ToolCall.normalize(call)
        before = stored_tokens(state)

        {state, content} =
          case run_compact(state) do
            {state, :changed} ->
              # how much the CONTEXT itself shrank — measured on the stored
              # messages, not `projected_tokens/1`. That value is the max of
              # the provider count and chars/4, and the provider count
              # includes the framework prompt + tool schemas the stored
              # context does NOT contain, so subtracting it credited the
              # whole per-request overhead as "reclaimed" (review N42) — on
              # a small context it could even report a win while the request
              # grew. The trailing "(now ...)" stays `projected_tokens`,
              # the number the budget block and the next trigger use.
              {state,
               "compacted: older messages summarized, ~#{reclaimed_tokens(state, before)} tokens reclaimed (now ~#{Compactor.projected_tokens(state)} of #{Compactor.window(state)})"}

            {state, :nothing} ->
              {state,
               "nothing to compact: no older exchange to summarize yet (context is " <>
                 "~#{Compactor.projected_tokens(state)} of #{Compactor.window(state)})"}

            {state, :interrupted} ->
              {state,
               "compaction stopped: you interrupted it; the context is unchanged " <>
                 "(~#{Compactor.projected_tokens(state)} of #{Compactor.window(state)})"}

            {state, {:failed, reason}} ->
              {state,
               "compaction failed (#{compact_reason(reason)}); the context is unchanged " <>
                 "(~#{Compactor.projected_tokens(state)} of #{Compactor.window(state)}). " <>
                 "Recent failures back off automatic retries for a few turns."}
          end

        result = %{id: id, name: CodingAgent.Core.Tools.Compact.name(), content: content}
        {state, [result | acc]}
      end)

    {state, Enum.reverse(results)}
  end

  # The stored-context token delta, the honest "reclaimed" number (N42).
  defp reclaimed_tokens(state, before) do
    max(before - stored_tokens(state), 0)
  end

  defp stored_tokens(state), do: div(Compaction.total_chars(state.context.messages), 4)

  # A short, model-facing reason for the failed-compaction result; the full
  # term is `inspect`'d so a provider struct does not bloat the tool text.
  defp compact_reason(reason) do
    case reason do
      :wall_clock_exceeded -> "summarizer timed out"
      :empty_summary -> "summarizer returned nothing"
      :backoff -> "a recent compaction failed, backing off"
      other -> inspect(other, printable_limit: 60)
    end
  end

  # The in-turn compaction body. The `idle_compaction_runner` seam (kept
  # in the worker snapshot) is reused so a test can drive the shrink
  # without a provider, exactly as the background pass does; otherwise
  # `compact_now/2` runs the real summarizer synchronously. Public for
  # tests (the result shape is core behavior).
  @doc false
  def run_compact(state) do
    case state.idle_compaction_runner do
      nil -> Compactor.compact_now(state)
      fun -> fun.(state)
    end
  end

  # Applies each todo call (the LAST one wins, as a full replace) and
  # returns the updated state plus one result per call. A malformed call
  # is an error result the model can correct; it changes nothing. The
  # list is broadcast so the TUI sidebar repaints.
  defp apply_todos(state, []), do: {state, []}

  defp apply_todos(state, d_calls) do
    {state, results} =
      Enum.reduce(d_calls, {state, []}, fn call, {state, acc} ->
        {id, _name, args} = ToolCall.normalize(call)

        case CodingAgent.Core.Tools.TodoWrite.parse(args) do
          {:ok, todos} ->
            broadcast(state, {:todos_updated, todos})

            result = %{
              id: id,
              name: CodingAgent.Core.Tools.TodoWrite.name(),
              content: todo_summary(todos)
            }

            {%{state | todos: todos}, [result | acc]}

          {:error, reason} ->
            result = %{
              id: id,
              name: CodingAgent.Core.Tools.TodoWrite.name(),
              content: "error: #{reason}"
            }

            {state, [result | acc]}
        end
      end)

    {state, Enum.reverse(results)}
  end

  defp todo_summary([]), do: "Cleared the todo list."

  defp todo_summary(todos) do
    open = Enum.count(todos, &(&1["status"] != "completed"))
    "Updated the todo list (#{length(todos)} items, #{open} open)."
  end

  # The `task` (subagent) calls in a round. Like `question`, they are
  # intercepted before the gate: the session runs a child, not a gated
  # tool action (ADR 017/018). The child's own tool calls are gated in the
  # child session.
  defp task_calls(calls) do
    Enum.filter(calls, fn call ->
      {_id, name, _args} = ToolCall.normalize(call)
      name == CodingAgent.Core.Tools.Task.name()
    end)
  end

  # A `task` call's children may not ask a human (ADR 017): a sibling call
  # the gate wanted to prompt is answered with a clear refusal instead of
  # parking the child forever.
  defp subagent_no_human_result(call) do
    {id, name, _} = ToolCall.normalize(call)

    %{
      id: id,
      name: name,
      content:
        "error: this call needs human approval, but a subagent has no human " <>
          "channel (ADR 017). Declare the authority in the subagent definition, " <>
          "or do this on the primary agent instead."
    }
  end

  # Runs each task call's child and returns its summary as a tool result.
  # A failed delegation returns an error result (the model can correct the
  # subagent_type and retry) rather than crashing the parent turn.
  #
  # A round's `task` calls run CONCURRENTLY, capped (ADR 018): delegating
  # to N repos should not take N child-turns end to end. The cap defaults
  # to Ollama's parallel limit and is configurable
  # (`Config.subagent_concurrency/1`). Results keep call order
  # (`ordered: true`), so a round's tool results are deterministic.
  #
  # `{:tool_started, "task"}` is published per call (as `ToolRunner` does
  # for a gated tool), so the status band reads "running task" for the
  # children's whole duration; the matching `{:tool_executed, ...}` is
  # published by `broadcast_tools/3` with the round's results.
  #
  # The tasks run under the turn supervisor with `async_stream_nolink`:
  # a raise inside `Subagent.run/2` (the seam loads definitions and
  # summarises a child state — third-party-adjacent code) must arrive as
  # an `{:exit, _}` element, not as an exit SIGNAL. Linked `Task.async_stream`
  # kills the caller instead — found in review F1 (a corrupted child
  # context made `summarize/1` raise, taking the parent's turn worker
  # down and leaving the session failed with no summary).
  defp run_subagents(state, task_calls) do
    Enum.each(task_calls, fn _call ->
      Events.publish(state.id, {:tool_started, CodingAgent.Core.Tools.Task.name()})
    end)

    cap = CodingAgent.Core.Config.subagent_concurrency(state.scope_root)

    Task.Supervisor.async_stream_nolink(
      task_supervisor(),
      task_calls,
      fn call -> CodingAgent.Core.Session.Subagent.run(state, call) end,
      max_concurrency: cap,
      ordered: true,
      # a child is a whole turn: it may run long, so no wall-clock cap.
      timeout: :infinity
    )
    |> Enum.zip(task_calls)
    |> Enum.map(fn
      {{:ok, result}, _call} -> result
      {{:exit, reason}, call} -> subagent_exit_result(call, reason)
    end)
  end

  defp subagent_exit_result(call, reason) do
    {id, name, _args} = ToolCall.normalize(call)
    %{id: id, name: name, content: "error: subagent crashed: #{inspect(reason)}"}
  end

  # Gate-side refusals are logged with their id and reason so a live
  # failure is traceable.
  defp log_refusal(call, message) do
    {id, _, _} = ToolCall.normalize(call)
    Logger.warning("#{message}: #{inspect(id)}")
  end

  # The turn reached its tool-round budget (ADR 025). This is NOT a
  # failure: the round's calls are discarded (never executed, never put
  # on the wire, so the context stays valid), a wrap-up instruction is
  # appended, ONE final provider call is made WITH TOOLS WITHHELD, and
  # the resulting summary ends the turn idle. The human keeps a usable
  # account and can continue with a fresh budget on the next prompt.
  #
  # A test-mode session (LLM-free) takes the structural skip, like the
  # compactor: the instruction is appended and the turn ends idle, but no
  # provider call is made.
  defp wrap_up(state, budget) do
    Logger.warning("tool-round budget reached: #{budget}")
    broadcast(state, {:info, "· turn budget reached (#{budget} rounds) — summarizing"})

    # The wrap-up instruction is PERSISTED (a synthetic user message, the
    # shape Compaction.apply/2 uses), so a resumed session — and the next
    # turn — sees the summary request and the model's answer that followed
    # it, rather than a context that jumps from the last tool result to an
    # unexplained assistant summary.
    context = Context.append(state.context, ReqLLM.Context.user(Prompt.wrap_up()))
    finish_wrap_up(%{state | context: context})
  end

  # test_mode is LLM-free: the structural skip (like the compactor's),
  # so the budget path is reachable without a provider. The instruction
  # is appended and the turn ends idle; no summary call is made.
  #
  # The :idle broadcast is what the production path gets from
  # `complete_turn/3`: the TUI treats session broadcasts as the authority
  # and ignores the decision reply, so a silent state change here would
  # leave the band on "running" after a budget stop (found by the TUI
  # tests once the reply stopped being authoritative).
  defp finish_wrap_up(%{test_mode: true} = state) do
    state = %{state | status: :idle}
    broadcast(state, {:status_changed, :idle})
    persist(state)
    {state, {:ok, state}}
  end

  defp finish_wrap_up(state) do
    case call_llm(state, tools: []) do
      {:ok, %{type: type, text: text, blocks: blocks, usage: usage}}
      when type in [:final_answer, :tool_calls] ->
        # :tool_calls should be impossible (tools were withheld); if a
        # provider emits one anyway, keep the text and end idle — never
        # loop the wrap-up.
        state = state |> add_usage(usage) |> complete_turn(text, blocks)
        {state, {:ok, state}}

      {:interrupted, partial} ->
        # same rule as the main loop: keep partial text, or end with a
        # note when nothing streamed (never an empty assistant message)
        state = interrupted_turn(state, partial)
        {state, {:ok, state}}

      {:error, reason} ->
        # the wrap-up call itself failed: this IS a failed turn, same as
        # any other provider error on the answer.
        state = state |> drop_interrupt() |> fail_turn(reason)
        {state, {:error, reason}}
    end
  end

  # A tool round is appended as ONE canonical exchange: the assistant
  # message declares every application call of the round, and every call
  # has exactly one result. Appending bare tool results without the
  # declaring assistant message (the old per-path behavior) ships an
  # orphaned exchange that strict OpenAI-compatible backends reject or
  # mis-associate by `tool_call_id` — and the ids of already-run auto
  # calls would otherwise vanish from the model's view entirely.
  defp complete_round(state, calls, results) do
    assistant_msg = assistant_message_for(calls)

    result_msgs =
      Enum.map(results, fn %{id: id, name: name, content: content} ->
        Context.tool_result_message(name, id, content)
      end)

    case ReqLLM.Context.append_tool_exchange(state.context, assistant_msg, result_msgs) do
      {:ok, context} ->
        %{
          state
          | context: context,
            pending_tool_calls: [],
            pending_round_calls: [],
            pending_round_results: []
        }

      {:error, reason} ->
        Logger.error("tool exchange failed: #{inspect(reason)}")
        state
    end
  end

  defp finish_round(state) do
    if state.test_mode do
      {state, {:ok, state}}
    else
      continue_loop(state)
    end
  end

  defp execute_tools(state, calls) do
    tools = ToolRunner.tools(state.policy, tool_scope(state))
    # {:tool_started, name} is published per call by ToolRunner, just
    # before that call runs (start/result interleave correctly).
    ToolRunner.execute(state.id, tools, calls)
  end

  defp broadcast_tools(state, calls, results) do
    by_id = Map.new(results, &{&1.id, &1.content})

    Enum.each(calls, fn call ->
      {id, name, args} = ToolCall.normalize(call)
      content = Map.get(by_id, id, "")
      broadcast(state, {:tool_executed, name, content, args})
    end)
  end

  # The registry narrowed by the policy (enabled whitelist + agent
  # disallowedTools) — see Session.ToolRunner.
  defp current_tools(state), do: ToolRunner.tools(state.policy, tool_scope(state))

  defp tool_scope(state) do
    ToolRunner.scope(
      state.scope_root,
      state.mounts,
      state.id,
      state.policy.shell_mode,
      depth: state.depth,
      subagents: state.subagents
    )
  end

  # Tool output is arbitrary bytes; scrub is the PREVENT side of the
  # poisoned-context guard (`Core.Text`). `sanitize_context/1` is the
  # HEAL side, for sessions persisted before this guard existed.

  # HEAL side of the poisoned-context guard: sessions persisted before
  # `scrub/1` existed (or written by an older build) can carry an invalid
  # byte in a tool result, which makes every request fail to encode. We
  # sanitize the context on the way OUT to the provider, so an already
  # broken session recovers on its next turn without hand-editing the
  # stored file. The stored context is also rewritten in place when a
  # difference is found, so the fix persists.
  defp sanitize_context(%Context{} = context) do
    messages = Context.to_list(context)

    case Enum.any?(messages, &message_invalid?/1) do
      false ->
        context

      true ->
        Context.new(Enum.map(messages, &sanitize_message/1))
    end
  end

  defp message_invalid?(%ReqLLM.Message{content: content}), do: content_invalid?(content)

  defp content_invalid?(content) when is_binary(content), do: not String.valid?(content)

  defp content_invalid?(content) when is_list(content) do
    Enum.any?(content, fn
      %ReqLLM.Message.ContentPart{text: t} when is_binary(t) -> not String.valid?(t)
      _ -> false
    end)
  end

  defp content_invalid?(_), do: false

  defp sanitize_message(%ReqLLM.Message{content: content} = msg) when is_binary(content) do
    %{msg | content: CodingAgent.Core.Text.scrub(content)}
  end

  defp sanitize_message(%ReqLLM.Message{content: content} = msg) when is_list(content) do
    parts =
      Enum.map(content, fn
        %ReqLLM.Message.ContentPart{text: t} = part when is_binary(t) ->
          %{part | text: CodingAgent.Core.Text.scrub(t)}

        other ->
          other
      end)

    %{msg | content: parts}
  end

  defp sanitize_message(msg), do: msg

  # The model a turn actually uses (ADR 017): the agent definition's
  # model when it sets one, otherwise the session's. The decision lives
  # in State so the compactor's summarize call resolves the SAME model
  # as the turn loop (Request divergence bug).
  @doc false
  @spec effective_model(State.t()) :: String.t() | nil
  defdelegate effective_model(state), to: State

  # The wire request for a state: the model input, the options (tools +
  # per-agent temperature), and the context to send. The context carries
  # the per-call environment block (ADR 024) — the stored context is not
  # mutated. Public so a test can assert the assembly without a provider.
  #
  # `overrides` lets the budget wrap-up (ADR 025) withhold tools
  # (`tools: []`) and send an alternate context without a second assembly
  # path.
  @doc false
  @spec wire_request(State.t(), keyword()) ::
          {:ok, String.t() | map(), keyword(), ReqLLM.Context.t()} | {:error, term()}
  def wire_request(state, overrides \\ []) do
    model = effective_model(state)
    context = Keyword.get(overrides, :context, state.context)
    tools = Keyword.get(overrides, :tools, current_tools(state))

    with {:ok, model_input, base_opts} <-
           Request.build(model, state.provider_config, state.scope_root) do
      opts =
        base_opts
        |> Keyword.put(:tools, tools)
        |> put_temperature(state.agent)
        |> put_reasoning_effort(state.reasoning_effort)

      context = Prompt.with_environment(context, model, state.scope_root)
      context = Prompt.with_todos(context, state.todos)
      context = Prompt.with_budget(context, budget_info(state))
      context = Prompt.with_capabilities(context, capability_info(state))
      {:ok, model_input, opts, context}
    end
  end

  # The numbers the budget block shows the model: the projected context
  # size and the two auto-summary lines, read from the SAME state the
  # sidebar mirrors and the compaction decision uses (ADR 029). A session
  # with no resolved window (a hand-built test state) sends no block.
  defp budget_info(%State{} = state) do
    %{
      used: Compactor.projected_tokens(state),
      window: Compactor.window(state),
      soft: Compactor.soft_limit(state),
      hard: Compactor.hard_limit(state),
      # the tool-round budget the guard checks (ADR 025), so the model can
      # see "turn 54 of 200" instead of decoding its own state blob. Read
      # through `tool_budget/1` — the SAME function `gate_tools` uses — so
      # the number shown and the number enforced cannot drift (review N66).
      rounds: state.tool_rounds,
      max_rounds: tool_budget(state)
    }
  end

  # What this session CANNOT do, read from the SAME state the tool
  # assembly and the gate use: the difference between the full registry
  # and the tools `wire_request/2` actually exposes (`ToolRunner.tools/2`
  # narrowed by the policy and the agent definition), plus the shell
  # root mode. No second policy read — the block is derived, so the
  # statement and the enforcement cannot drift (the budget-block rule).
  defp capability_info(%State{} = state) do
    scope = tool_scope(state)

    full_names =
      scope
      |> CodingAgent.Core.Tools.all()
      |> Enum.map(& &1.name)

    exposed_names =
      state.policy
      |> ToolRunner.tools(scope)
      |> Enum.map(& &1.name)

    %{
      missing: Enum.sort(full_names -- exposed_names),
      shell_mode: Permissions.shell_mode(state.policy)
    }
  end

  # One provider call, bounded by the configured retry policy. A transient
  # transport TIMEOUT (req_llm's structured `%ReqLLM.Error.API.Timeout{}`)
  # is retried up to `provider_retries` times with `provider_retry_delay_ms`
  # between attempts; every other failure ends the turn immediately, as
  # before.
  defp call_llm(state, overrides \\ []) do
    retries = Config.provider_retries(state.scope_root)
    delay = Config.provider_retry_delay_ms(state.scope_root)
    retry_llm(state, retries, delay, fn -> stream_attempt(state, overrides) end)
  end

  # The retry loop, separable from the provider call so the DECISION is
  # unit-testable without a provider. `attempt_fun` produces each attempt
  # and `wait_fun.(id, ms)` blocks (returning true when the human stopped).
  @doc false
  @spec retry_llm(State.t(), non_neg_integer(), non_neg_integer(), (-> term()), (String.t(),
                                                                                 non_neg_integer() ->
                                                                                   boolean())) ::
          term()
  def retry_llm(state, retries, delay, attempt_fun, wait_fun \\ &wait_or_interrupt/2) do
    try_llm(state, retries, retries, delay, attempt_fun, wait_fun)
  end

  defp try_llm(state, total, left, delay, attempt_fun, wait_fun) do
    result = attempt_fun.()

    case llm_retry(result, left, streamed_output?(state.id), total) do
      :retry_timeout ->
        retry_attempt(state, total, left, delay, attempt_fun, wait_fun, "provider timeout")

      :retry_empty ->
        retry_attempt(
          state,
          total,
          left,
          delay,
          attempt_fun,
          wait_fun,
          "provider returned nothing"
        )

      :give_up ->
        result

      {:give_up, reason} ->
        {:error, reason}
    end
  end

  # The PURE retry decision (no side effects), so it is directly testable:
  #
  #   * `:retry_timeout` — a transient timeout with nothing streamed (a
  #     timeout after partial output must NOT re-ask the model and
  #     duplicate text the human already saw);
  #   * `:retry_empty`   — a clean finish that carried NO ANSWER **and
  #     streamed nothing**. "No answer" is `text: ""` and `tool_calls:
  #     []`; reasoning blocks are ignored, because the first cut keyed on
  #     `blocks: []` and so a reasoning-only finish (text `""`, no calls,
  #     only `{:reasoning, …}` blocks) was accepted as a successful turn
  #     — the session went idle showing just its last thought, the very
  #     symptom this ADR set out to kill.
  #   * `:give_up`       — return the attempt's result unchanged (a
  #     non-timeout failure, or a successful/partial attempt);
  #   * `{:give_up, reason}` — a named failure. Empty with nothing
  #     streamed and retries exhausted, or empty AFTER output streamed:
  #     like a timeout after partial output, re-asking would duplicate
  #     what the human already saw (here, the displayed reasoning), so it
  #     fails the turn loudly instead.
  @doc false
  @spec llm_retry(term(), non_neg_integer(), boolean(), non_neg_integer()) ::
          :retry_timeout | :retry_empty | :give_up | {:give_up, term()}
  def llm_retry({:error, reason}, left, streamed?, _total) when left > 0 do
    if CodingAgent.Core.Failure.retryable_timeout?(reason) and not streamed? do
      :retry_timeout
    else
      :give_up
    end
  end

  def llm_retry({:ok, %{text: "", tool_calls: []}}, left, streamed?, total) do
    cond do
      # reasoning already reached the human: never re-ask on top of it
      streamed? -> {:give_up, {:empty_provider_response, total}}
      left > 0 -> :retry_empty
      true -> {:give_up, {:empty_provider_response, total}}
    end
  end

  def llm_retry(_result, _left, _streamed?, _total), do: :give_up

  # One retry: announce it, wait (honoring esc), then try again — or end
  # the turn as an interrupt when the human stopped during the back-off.
  defp retry_attempt(state, total, left, delay, attempt_fun, wait_fun, label) do
    n = total - left + 1
    Logger.warning("#{label}; retry #{n}/#{total} in #{delay}ms")
    broadcast(state, {:info, "· #{label} — retry #{n}/#{total} in #{div(delay, 1000)}s"})

    if wait_fun.(state.id, delay) do
      {:interrupted, ""}
    else
      try_llm(state, total, left - 1, delay, attempt_fun, wait_fun)
    end
  end

  # A single streamed provider attempt. `consume_stream` throws
  # `{:stream_error, ...}` on stream failures and returns
  # `{:interrupted, text}` when the user stops the turn. Catch the throw
  # HERE: a transport error is a failed turn, an interrupt is a finished
  # (partial) turn — neither may crash the session (the GenServer used to
  # terminate on this path — found in the 4a live smoke test).
  defp stream_attempt(state, overrides) do
    # Reset the "did anything stream" flag for THIS attempt: a failure
    # before `consume_stream` (a connect timeout in `stream_text`) must
    # not read a stale `true` from an earlier round and refuse to retry.
    Process.put(output_key(state.id), false)

    with {:ok, model_input, opts, context} <- wire_request(state, overrides) do
      with {:ok, stream_response} <-
             ReqLLM.stream_text(model_input, sanitize_context(context), opts) do
        events = ReqLLM.StreamResponse.events(stream_response)

        # Hand the active stream's hard-cancel to the interrupt
        # coordinator: a stop request then closes the underlying
        # ReqLLM.StreamResponse, which cancels the HTTP work and
        # releases the session's blocked `next` call — the only way to
        # stop a reasoning-only stream that never emits another delta.
        Interrupt.register(state.id, fn -> ReqLLM.StreamResponse.close(stream_response) end)

        try do
          case consume_stream(events, state.id) do
            {:interrupted, partial} ->
              {:interrupted, partial}

            {text, tool_calls, blocks} ->
              # real token accounting (sidebar, token-based compaction):
              # the metadata task resolves after the stream is fully consumed
              usage = ReqLLM.StreamResponse.usage(stream_response)

              {:ok,
               %{
                 type: classify(tool_calls),
                 text: text,
                 tool_calls: tool_calls,
                 blocks: blocks,
                 usage: usage
               }}
          end
        catch
          {:stream_error, error} ->
            # The stream failed mid-flight, but `req_llm`'s transport
            # retry loop (`ReqLLM.Streaming.Retry.stream/6`) may still be
            # retrying on a fresh socket BEHIND this returned error
            # (review N29: an idle timeout is classified `:retry` there,
            # not `:no_retry`, so it retries even though the pre-start
            # classification path would not). The session is about to
            # retry the same provider itself, so an abandoned stream must
            # be closed — otherwise the old attempts keep hitting the
            # provider, adding parallel load and cost (up to 4 × 4 = 16
            # provider hits for one failed turn). Same close the hard
            # interrupt path uses.
            _ = safe_close(stream_response)
            {:error, {:stream_error, error}}
        after
          Interrupt.unregister(state.id)
        end
      end
    end
  end

  # Best-effort close of an abandoned stream response: it must never
  # raise into the catch clause that is already handling a failure.
  defp safe_close(stream_response) do
    ReqLLM.StreamResponse.close(stream_response)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Waits `ms` in small chunks so a user stop (esc) is honored promptly
  # instead of after the whole back-off. Returns true when interrupted.
  defp wait_or_interrupt(_id, ms) when ms <= 0, do: false

  defp wait_or_interrupt(id, ms) do
    chunk = min(ms, 100)
    Process.sleep(chunk)

    if Interrupt.requested?(id) do
      true
    else
      wait_or_interrupt(id, ms - chunk)
    end
  end

  @doc false
  # Test-only handle on the failed-turn path, so a test can drive the
  # "a turn ended without consuming its held round" state without a
  # provider. Not part of the driver contract.
  @spec debug_fail_turn(State.t(), term()) :: State.t()
  def debug_fail_turn(state, reason), do: fail_turn(state, reason)

  @doc false
  def consume_stream(events, session_id) do
    partial_key = {__MODULE__, :partial, session_id}
    Process.put(partial_key, "")
    # Whether this attempt produced anything the human could have seen.
    # Kept OUTSIDE the try (not cleared in `after`) so `call_llm` can read
    # it after a thrown stream error and refuse to retry a timeout that
    # would duplicate already-rendered output.
    Process.put(output_key(session_id), false)

    try do
      events
      |> Enum.reduce_while({:streaming, "", [], []}, fn event, acc ->
        event
        |> handle_event(acc, session_id, partial_key)
        |> interrupt_check(session_id)
      end)
      |> interrupt_result(session_id)
    catch
      # Narrow race: Interrupt fires StreamResponse.close from a spawned
      # process; if it lands between two events, the next
      # StreamServer.next call reaches the already-stopped server and
      # exits. If a stop was requested that is exactly the intended
      # outcome — return the partial text streamed so far instead of
      # letting the exit crash the session. Any other exit is a real
      # stream failure and is re-raised.
      :exit, reason ->
        if Interrupt.requested?(session_id) do
          {:interrupted, Process.get(partial_key, "")}
        else
          :erlang.raise(:exit, reason, __STACKTRACE__)
        end
    after
      Process.delete(partial_key)
    end
  end

  defp output_key(session_id), do: {__MODULE__, :output, session_id}

  # True when the LAST `consume_stream/2` emitted a visible delta (text,
  # reasoning or a tool call). Read by the retry policy in `call_llm/2`.
  defp streamed_output?(session_id), do: Process.get(output_key(session_id), false)

  defp interrupt_result({:interrupted, text, _calls, _blocks}, _session_id),
    do: {:interrupted, text}

  defp interrupt_result({:streaming, text, calls, blocks}, session_id) do
    # A hard cancel (Interrupt fires StreamResponse.close) empties the
    # provider queue and ends the stream with a plain `:halt` — no
    # further event reaches interrupt_check. Classify that as an
    # interrupt too, so the partial answer is kept instead of looking
    # like a clean finish.
    if Interrupt.requested?(session_id) do
      {:interrupted, text}
    else
      # blocks are accumulated in prepend order; reverse to stream order
      # so the display view reads as it was written (ADR 020)
      {text, Enum.reverse(calls), Enum.reverse(blocks)}
    end
  end

  # Broadcast the event's payload and fold it into the accumulator. The
  # flag check lives in interrupt_check/2 applied after EVERY event (not
  # per clause): a non-delta event after a hard cancel must also halt, or
  # the next pull would hit the already-stopped StreamServer and exit.
  #
  # The accumulator also folds an ORDERED block list (the display view:
  # reasoning and answer text in the order the provider streamed them,
  # one block per contiguous run, NOT one row per delta). This is core
  # data now (ADR 020): the display view is persisted, so the session
  # owns its shape. The UI renders from it; it does not invent it.
  defp handle_event(
         %{type: :text_delta, data: delta},
         {:streaming, acc, calls, blocks},
         session_id,
         key
       ) do
    broadcast_text(session_id, delta)
    partial = acc <> delta
    Process.put(key, partial)
    Process.put(output_key(session_id), true)
    {:streaming, partial, calls, append_block(blocks, :assistant, delta)}
  end

  defp handle_event(
         %{type: :reasoning_delta, data: delta},
         {:streaming, acc, calls, blocks},
         session_id,
         key
       ) do
    broadcast_reasoning(session_id, delta)
    Process.put(key, acc)
    Process.put(output_key(session_id), true)
    {:streaming, acc, calls, append_block(blocks, :reasoning, delta)}
  end

  defp handle_event(
         %{type: :tool_call, data: call},
         {:streaming, acc, calls, blocks},
         session_id,
         _key
       ) do
    Process.put(output_key(session_id), true)
    {:streaming, acc, [call | calls], blocks}
  end

  defp handle_event(%{type: :error, data: error}, _acc, _session_id, _key) do
    throw({:stream_error, error})
  end

  defp handle_event(_event, acc, _session_id, _key), do: acc

  # One block per contiguous run of the same kind: a delta extends the
  # last block when its kind matches, else starts a new one. `\r` is
  # stripped (reasoning arrives with CRLF from some providers).
  defp append_block([{kind, text} | rest], kind, delta),
    do: [{kind, text <> String.replace(delta, "\r", "")} | rest]

  defp append_block(blocks, kind, delta),
    do: [{kind, String.replace(delta, "\r", "")} | blocks]

  # The user's stop request lands in the coordinator's ETS flag
  # (`Interrupt.request/1` cannot GenServer.call the session — it is busy
  # consuming this very stream). Checked after every stream event; stop
  # early keeping the partial text as the turn's answer (opencode esc
  # parity).
  defp interrupt_check({:streaming, acc, calls, blocks}, session_id) do
    if Interrupt.requested?(session_id) do
      {:halt, {:interrupted, acc, calls, blocks}}
    else
      {:cont, {:streaming, acc, calls, blocks}}
    end
  end

  defp classify([]), do: :final_answer
  defp classify(_calls), do: :tool_calls

  # cumulative session usage: input+output per turn; cost only when
  # the provider prices it (ollama cloud: usage.cost may be nil)
  @doc """
  Accumulates one turn's provider usage into the session state
  (cumulative input/output, last turn's input as the compaction
  measure, cost when priced) and broadcasts {:usage_updated, usage}.
  Public for tests: the accounting is core behavior, and the tests
  are LLM-free so they exercise it directly.
  """
  def add_usage(state, usage) do
    next = Usage.add(state.usage, usage)
    # nil usage leaves the totals untouched — do not broadcast a no-op
    if next == state.usage do
      state
    else
      state = %{state | usage: next}
      broadcast(state, {:usage_updated, next})
      state
    end
  end

  defp complete_turn(state, text, blocks) do
    context =
      state.context
      |> Context.append(ReqLLM.Context.assistant(text))

    state = %{state | context: context, status: :idle}
    # the display view (ADR 020): the ordered reasoning/answer blocks the
    # stream produced, plus the full answer when nothing streamed (a
    # non-streamed or resumed turn produces no deltas)
    state = record_display_blocks(state, blocks)
    state = ensure_display_answer(state, text, blocks)

    broadcast(state, {:llm_message, text})
    broadcast(state, {:status_changed, :idle})
    persist(state)
    state
  end

  # Append the streamed reasoning/answer blocks in order. Reasoning is the
  # thing the old store could not keep: it lives only here, never in the
  # agent view (ADR 020).
  defp record_display_blocks(state, blocks) do
    agent = state.agent && state.agent.name

    Enum.reduce(blocks, state, fn {kind, text}, acc ->
      case display_kind(kind) do
        nil -> acc
        dk -> append_display(acc, dk, text, agent)
      end
    end)
  end

  # When no assistant DELTA streamed but there is a final answer (a
  # resumed/non-streamed turn), the answer would otherwise be missing
  # from the display view: append it as one assistant block.
  defp ensure_display_answer(state, text, blocks) do
    if text != "" and not Enum.any?(blocks, fn {k, _} -> k == :assistant end) do
      append_display(state, :assistant, text, state.agent && state.agent.name)
    else
      state
    end
  end

  defp display_kind(:assistant), do: :assistant
  defp display_kind(:reasoning), do: :reasoning
  defp display_kind(_), do: nil

  defp append_display(state, kind, text, agent) do
    if String.trim(text) == "" do
      state
    else
      _ = Store.append_display(state.id, kind, text, agent: agent)
      state
    end
  end

  # -- Background compaction (ADR 037): the idle soft pass and /compact -------

  # Start the background soft pass when a turn ends IDLE and the session
  # is over the soft limit. The summarize call is slow, so it runs off the
  # session process; the context FINGERPRINT captured here is what
  # `handle_info({ref, ...})` compares against, so a result produced for a
  # context that has since changed (a new turn started) is discarded. The
  # hard, pre-call pass in `continue_loop/1` covers the busy case.
  defp start_idle_compaction(%State{status: :idle} = state) do
    if state.test_mode or Compactor.projected_tokens(state) < Compactor.soft_limit(state) do
      state
    else
      fp = context_fingerprint(state)
      ref = spawn_compaction(state, :soft)

      %{state | idle_compaction_ref: ref, idle_compaction_fp: fp}
    end
  end

  defp start_idle_compaction(state), do: state

  # One background slot for both passes: the idle soft limit (`:soft`) and
  # the manual `/compact` (`:manual`). The runner seam replaces the body
  # either way, so a test drives a compaction without a provider.
  defp spawn_compaction(state, mode) do
    snapshot = worker_snapshot(state)
    runner = state.idle_compaction_runner

    body =
      case runner do
        nil -> fn -> default_compact(snapshot, mode) end
        fun -> fn -> fun.(snapshot) end
      end

    Task.Supervisor.async_nolink(task_supervisor(), body).ref
  end

  defp default_compact(state, :soft), do: Compactor.maybe_compact_idle(state)
  defp default_compact(state, :manual), do: Compactor.compact_now(state)

  # A cheap, exact identity of the context the task was started for.
  # `:erlang.phash2/1` over the message list is stable for equal content
  # and changes on any append/rewrite, which is all the guard needs.
  defp context_fingerprint(state), do: :erlang.phash2(state.context.messages)

  # Apply a background compaction result only if the context still matches
  # the fingerprint captured at start; otherwise discard it (a new turn
  # began while the summary ran). Only the context, usage and backoff are
  # adopted from the task's state — it is a worker_snapshot, so its
  # subscribers/worker handles are stale. `usage` comes along because a
  # successful compaction resets `last_input_tokens` to the shrunk
  # context's estimate (see Compactor.note_shrunk_context/1), and the
  # sidebar must stop showing the pre-compaction count.
  defp apply_compaction_result(state, new_state) do
    fp = state.idle_compaction_fp
    state = %{state | idle_compaction_ref: nil, idle_compaction_fp: nil}

    cond do
      fp == nil ->
        state

      context_fingerprint(state) != fp ->
        # stale: the context changed under the summary; drop it
        state

      true ->
        state = %{
          state
          | context: new_state.context,
            usage: new_state.usage,
            compaction_backoff: new_state.compaction_backoff
        }

        persist(state)
        state
    end
  end

  # Compaction is delegated to `CodingAgent.Core.Session.Compactor`
  # (trigger decision, summarize task, backoff); nothing of it lives
  # here — the loop only asks "should the context shrink?" and gets
  # {state, changed?} back.

  defp fail_turn(state, reason) do
    # the turn is over in every branch from here — drop any stale
    # user-interrupt flag so the NEXT turn starts clean
    drop_interrupt(state)
    state = %{state | status: :error, last_error: reason} |> drop_held_round()
    broadcast(state, {:status_changed, :error, reason})
    persist(state)
    state
  end

  # A finished turn holds no round. `complete_turn` already clears the
  # hold through `complete_round`, but a turn can also end WITHOUT one —
  # the commit in `finish_round` aborts (a context that refuses the
  # exchange) and returns the state with `pending_round_*` still set, and
  # `fail_turn` sets :error over the same state. Either left a session
  # that Claims to be idle/error while holding a round: the UI has no
  # prompt to draw (there is no pause), no turn to run, and no way back —
  # found live on a session that sat as `:idle` with an unanswered
  # webfetch round since 14:59, invisible until a restart, and dead after
  # that because the turn that would have consumed the round was gone.
  #
  # The dropped calls are answered by the MODEL, not by us: the next turn
  # reads the exchange as unanswered and can redo the call. Nothing is
  # silently lost, which is why this clears instead of parking.
  defp drop_held_round(%{pending_round_calls: []} = state), do: state

  defp drop_held_round(state) do
    Logger.warning(
      "session #{state.id} ended a turn holding #{length(state.pending_round_calls)} " <>
        "undecided call(s); dropping the held round"
    )

    %{state | pending_tool_calls: [], pending_round_calls: [], pending_round_results: []}
  end

  # turn-end cleanup: the stop flag is per-turn, never carries over
  defp drop_interrupt(state) do
    Interrupt.clear(state.id)
    state
  end

  # Slice 4a: every turn boundary leaves a persisted snapshot. A crash
  # mid-turn loses at most the current turn — the previous boundary is
  # on disk. Failures are logged, never raised: an unwritable disk
  # must not kill a working session.
  #
  # A subagent child (`persist?: false`) is NOT persisted: its summary is
  # the durable record, carried in the parent's context, and a picker
  # entry of its own would be noise (ADR 018: ephemeral children). The
  # in-memory session still works; only the disk write is skipped.
  #
  # Runtime-only fields are stripped before the write: worker refs and
  # the queue are process-local, and the test seam is a closure that
  # must never be serialized (Store.restore clears them too, belt and
  # braces for snapshots written by an older build).
  defp persist(%{persist?: false} = state), do: state

  defp persist(state) do
    case state |> worker_snapshot() |> strip_runner() |> Store.save() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("session persist failed: #{inspect(reason)}")
    end

    state
  end

  defp strip_runner(state),
    do: %{state | turn_runner: nil, subagent_runner: nil, idle_compaction_runner: nil}

  # -- Infrastructure ---------------------------------------------------------

  defp broadcast_reasoning(session_id, delta),
    do: Events.publish(session_id, {:reasoning_deltas, delta})

  defp broadcast_text(session_id, delta),
    do: Events.publish(session_id, {:llm_deltas, delta})

  # The single publish point, and now also the display-view write point
  # for the events that are part of what the user SAW but live nowhere
  # else: info notes (compaction, stops, gate refusals) and tool results.
  # Reasoning/answer/user are appended by their own paths (they carry the
  # ordered blocks); broadcasting here would double-record them.
  defp broadcast(state, event) do
    record_display_event(state, event)
    Events.publish(state.id, event)
  end

  defp record_display_event(state, {:info, text}) when is_binary(text),
    do: _ = Store.append_display(state.id, :info, text, agent: state.agent && state.agent.name)

  defp record_display_event(state, {:tool_executed, name, content, args}),
    do: _ = Store.append_display(state.id, :tool, content, meta: {:tool, name, args})

  # older/synthetic events without arguments (a resumed or hand-built
  # event) still record; the meta simply carries no args
  defp record_display_event(state, {:tool_executed, name, content}),
    do: _ = Store.append_display(state.id, :tool, content, meta: {:tool, name, %{}})

  defp record_display_event(_state, _event), do: :ok
end
