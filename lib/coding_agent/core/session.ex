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

  alias CodingAgent.Core.Config
  alias CodingAgent.Core.Events
  alias CodingAgent.Core.Interrupt
  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.ToolCall
  alias CodingAgent.Core.Session.{Compactor, Gate, Request, State, Store, ToolRunner}
  alias ReqLLM.Context

  # GenServer call timeout. Gate decisions can take arbitrarily long
  # (the user is a human reading the approval prompt), so decide/2 and
  # friends use :infinity. The LLM call inside a turn is bounded by the
  # provider's own timeouts, not this one.
  @call_timeout :infinity

  # live report: a real multi-step task burned 16 gate rounds and the
  # turn died with "tool loop limit reached: 12" — the agent then
  # complained about "flaky parallel calls". 12 was a phase-2 guess;
  # GLM does one small grep per round: a review turn burned 25 rounds
  # live (7ce59be made the counter per-turn, but 25 still dies on a
  # legit review). The default is Core.Config's — the guard exists to
  # catch a runaway loop, and its cost is proportional to the work
  # actually requested.
  defp max_tool_rounds, do: CodingAgent.Core.Config.max_tool_rounds()

  # providers whose requests need no api_key option

  @framework_prompt """
  You are a coding assistant embedded in a terminal tool. Be concise and
  precise. When you intend to use a tool, emit the tool call; do not
  narrate that you are about to call tools.
  """

  # -- Client API -------------------------------------------------------------

  @doc "Starts a session process as part of the supervision tree."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Returns the session's current state (messages, status)."
  @spec state(String.t()) :: State.t() | {:error, :not_found}
  def state(id), do: GenServer.call(via(id), :state)

  @doc """
  Updates the LIVE session's in-memory id after a Store rename so its
  next save lands under the new name (no stale-file resurrection).
  The registry keeps the old key — the process remains addressable
  under the id it was started with until it exits; future mounts go
  through the renamed file.
  """
  def set_id(id, new_id) do
    GenServer.call(via(id), {:set_id, new_id})
  end

  @doc "Model-menu switch: swap the wire model for the NEXT turn."
  def set_model(id, model) do
    GenServer.call(via(id), {:set_model, model})
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
    GenServer.call(via(id), {:set_agent, name}, @call_timeout)
  end

  @doc """
  Subscribes the CALLER to session events (streaming deltas, status
  changes). Events arrive as `{:agent, event}` messages.

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
      usage: state.usage,
      compaction_warned: state.compaction_warned,
      compaction_backoff: state.compaction_backoff,
      status: state.status,
      pending_tool_calls: state.pending_tool_calls,
      pending_round_calls: state.pending_round_calls,
      pending_round_results: state.pending_round_results
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

  # The persisted agent name, or nil when the definition is gone /
  # non-primary. A missing definition must not brick a resume.
  defp resumable_agent_name(%State{agent: nil}), do: nil

  defp resumable_agent_name(%State{agent: %{name: name}, scope_root: root}) do
    case Config.agents(root) do
      {:ok, agents} ->
        if Enum.any?(agents, &(&1.name == name and &1.mode == :primary)), do: name, else: nil

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
  Supplies decisions for pending tool calls (ADR 010: approve / edit /
  reject, one decision per call) and resumes the interrupted turn.
  """
  @spec decide(String.t(), [%{id: String.t(), decision: :approve | :reject | {:edit, map()}}]) ::
          {:ok, State.t()} | {:error, term()}
  def decide(id, decisions), do: GenServer.call(via(id), {:decide, decisions}, @call_timeout)

  @doc """
  Feeds tool calls directly into the permission gate, bypassing the
  LLM. Test-only hook (phase-2 test support); not part of the public
  driver contract. Refuses a non-test session with
  `{:error, :not_test_mode}` — it must never silently turn a live
  session into a test-mode one.
  """
  @doc since: "0.1.0"
  @spec debug_gate(String.t(), [map()]) :: :ok | {:error, term()}
  def debug_gate(id, calls) when is_list(calls) do
    GenServer.call(via(id), {:debug_gate, calls}, @call_timeout)
  end

  defp via(id), do: {:via, Registry, {CodingAgent.Registry, {:session, id}}}

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

    system_prompt = Keyword.get(opts, :system_prompt, @framework_prompt)
    test_mode = Keyword.get(opts, :test_mode, false)
    policy = Keyword.get(opts, :policy) || snapshot.permissions

    # Resume support (4a): a resumed session must carry the persisted
    # usage forward. last_input_tokens is the ONLY sound compaction
    # measure; without it decide/2 takes the chars fallback and compacts
    # a just-resumed session on its first command regardless of the real
    # token count (found live: every resumed session compacted at once).
    usage = Keyword.get(opts, :usage) || %{input_tokens: 0, output_tokens: 0, cost: nil}
    compaction_warned = Keyword.get(opts, :compaction_warned, false)
    compaction_backoff = Keyword.get(opts, :compaction_backoff, 0)
    # test seam: replace the worker's blocking body. Lets a test hold a
    # turn "in flight" (and assert the session still answers) without a
    # provider. Never set in production.
    turn_runner = Keyword.get(opts, :turn_runner)

    # A session that was parked at the gate when it last stopped resumes
    # PARKED, not idle: the pending calls (and the half of the round that
    # was already decided — auto-executed, blacklist/policy-denied) come
    # back so `decide/2` can finish the exchange. Dropping them used to
    # silently discard work the user then had to redo.
    status = Keyword.get(opts, :status, :idle)
    pending_tool_calls = Keyword.get(opts, :pending_tool_calls, [])
    pending_round_calls = Keyword.get(opts, :pending_round_calls, [])
    pending_round_results = Keyword.get(opts, :pending_round_results, [])

    # Project memory (4c): AGENTS.md at the scope root is read once at
    # session start and appended to the system prompt — the long-term
    # memory tier that writes knowledge down as files (memory.rst).
    # Missing file is the normal case; unreadable/corrupt content
    # degrades to a warning, never an error.
    system_prompt = append_project_memory(system_prompt, scope_root)

    # Agent definition (ADR 017). `:agent` names a definition; when given,
    # its prompt is composed onto the (already memory-augmented) framework
    # prompt and its permission layer is applied to the policy
    # (restrictive only). Absent => the pre-agent behaviour, so tests and
    # headless callers are unchanged.
    #
    # base_policy/base_prompt are the values BEFORE the agent layer, kept
    # so a later set_agent/2 (Tab switch) recomputes from scratch:
    # apply_agent narrows, so stacking a second definition would compound
    # the first's restrictions.
    base_policy = policy
    base_prompt = system_prompt

    {agent, policy, system_prompt} =
      case resolve_agent(Keyword.get(opts, :agent), policy, system_prompt, snapshot.agents) do
        {:ok, agent, policy, prompt} -> {agent, policy, prompt}
        {:error, reason} -> raise ArgumentError, format_agent_error(reason)
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
       # resumed state carried forward: usage drives the compaction
       # trigger (see above), warned/backoff avoid re-warning and
       # re-retrying a summarize that already failed before the restart
       usage: usage,
       compaction_warned: compaction_warned,
       compaction_backoff: compaction_backoff,
       test_mode: test_mode,
       turn_runner: turn_runner
     )}
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
            composed = compose_agent_prompt(system_prompt, agent)
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

  defp compose_agent_prompt(framework_prompt, agent) do
    case String.trim(agent.prompt) do
      "" -> framework_prompt
      prompt -> framework_prompt <> "\n\n" <> prompt
    end
  end

  # AGENTS.md at the scope root: project conventions for the agent
  # (the pragmatic long-term memory: knowledge written down as files,
  # pulled back by this loader instead of exotic memory systems).
  @agents_file "AGENTS.md"
  @agents_max_bytes 64 * 1024

  defp append_project_memory(prompt, scope_root) do
    file = scope_root && Path.join(scope_root, @agents_file)

    cond do
      not is_binary(file) ->
        prompt

      not File.regular?(file) ->
        prompt

      true ->
        case File.read(file) do
          {:ok, bytes} when byte_size(bytes) <= @agents_max_bytes ->
            prompt <> "\n\n" <> project_memory_section(bytes)

          {:ok, bytes} when byte_size(bytes) > @agents_max_bytes ->
            Logger.warning("AGENTS.md larger than 64 KiB; truncated for the system prompt")

            prompt <> "\n\n" <> project_memory_section(binary_part(bytes, 0, @agents_max_bytes))

          {:error, reason} ->
            Logger.warning("AGENTS.md unreadable: #{inspect(reason)}")
            prompt
        end
    end
  end

  defp project_memory_section(text) do
    """
    # Project memory (AGENTS.md)

    Conventions and context for THIS project, written by the team:

    #{String.trim_trailing(text)}
    """
  end

  defp replace_system_prompt(context, prompt) do
    messages = ReqLLM.Context.to_list(context)

    case messages do
      [%ReqLLM.Message{role: :system} | rest] ->
        ReqLLM.Context.new([ReqLLM.Context.system(prompt) | rest])

      _ ->
        ReqLLM.Context.new([ReqLLM.Context.system(prompt) | messages])
    end
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, {:ok, state}, state}

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
    {:reply, :ok, struct!(state, model: model)}
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
    # system message is replaced in place (index 0) when present.
    case resolve_agent(name, state.base_policy, state.base_prompt, agents_of(state)) do
      {:ok, agent, policy, prompt} ->
        context = replace_system_prompt(state.context, prompt)
        new_state = %{state | agent: agent, policy: policy, context: context}
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

  def handle_call({:debug_gate, calls}, _from, %{test_mode: true} = state) do
    # test_mode is REQUIRED, never set here: it used to be flipped true
    # unconditionally, so a live session that ever touched the hook
    # raised "test-mode session reached call_llm" on its next real turn.
    # Callers (all tests) already start the session with test_mode: true.
    state = %{state | status: :running, tool_rounds: 0}
    {state, _result} = gate_tools(state, calls)
    {:reply, :ok, state}
  end

  def handle_call({:debug_gate, _calls}, _from, state) do
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
      broadcast(state, {:tool_executed, r.name, r.content})
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

  # A subscribed process died: drop its monitor.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, monitor)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
          turn_agents: state.turn_agents ++ [agent]
      }

    broadcast(state, {:turn_started, agent})
    broadcast(state, {:status_changed, :running})
    state
  end

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
  # carries only durable content plus the test seam. subscribers are
  # cleared too: they are live monitor refs, not data — the worker must
  # never persist its stale copy (and it broadcasts via the Registry,
  # not this list).
  defp worker_snapshot(state) do
    %{
      state
      | worker_ref: nil,
        worker_from: nil,
        queued_calls: [],
        pending_agent: :none,
        pending_model: :none,
        subscribers: [],
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
    drain_queue(new_state)
  end

  # A mid-turn set_agent/set_model applied at the turn boundary. Agent
  # switches recompute from the base values (no compounding) and replace
  # the system prompt in place.
  defp apply_pending_switches(state, session) do
    state =
      case session.pending_model do
        :none -> state
        model -> %{state | model: model}
      end

    case session.pending_agent do
      :none ->
        state

      {:set, agent, policy, prompt} ->
        context = replace_system_prompt(state.context, prompt)
        %{state | agent: agent, policy: policy, context: context}
    end
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
        {:ok, %{type: :final_answer, text: text, usage: usage}} ->
          state = state |> add_usage(usage) |> drop_interrupt() |> complete_turn(text)
          {state, {:ok, state}}

        {:ok, %{type: :tool_calls, tool_calls: calls, usage: usage}} ->
          state = state |> add_usage(usage) |> drop_interrupt()
          gate_tools(state, calls)

        # user stop (Interrupt.request/1): the partial text streamed so
        # far becomes the turn's answer (opencode esc parity — nothing
        # lost, the model can be nudged on from there)
        {:interrupted, partial} ->
          state = state |> drop_interrupt() |> complete_turn(partial)
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

  # The permission checkpoint (ADR 010): read-only tools pass by policy
  # (allow class defaults); state-changing tools get the effective
  # decision. :ask pauses the session (:interrupted) until the driver
  # supplies decisions for every pending call via decide/3.
  defp gate_tools(state, calls) do
    if state.tool_rounds >= max_tool_rounds() do
      Logger.error("tool loop limit reached: #{max_tool_rounds()}")

      # tell the user IN the transcript (a bare error turn is a
      # mystery — the user then asks 'what stopped it now?')
      broadcast(
        state,
        {:info,
         "· turn stopped: #{max_tool_rounds()} tool rounds used (the per-turn guard) — ask it to continue for another budget"}
      )

      state = fail_turn(state, {:tool_loop_limit, max_tool_rounds()})
      {state, {:error, {:tool_loop_limit, max_tool_rounds()}}}
    else
      state = %{state | tool_rounds: state.tool_rounds + 1}

      # All gate policy lives in Session.Gate: it buckets this round's
      # calls (blacklist / escalation-without-reason / explicit deny /
      # allow / ask) using the one Permissions.effective/4 path.
      plan = Gate.classify(state.id, state.policy, state.scope_root, calls)

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

      # Results already decided for this round, before any human input.
      known_calls = plan.blacklisted ++ plan.no_reason ++ plan.denied

      known_results =
        blacklist_results ++
          no_reason_results ++ Enum.map(plan.denied, &Gate.denied_result/1)

      if plan.pending == [] do
        auto_results = execute_tools(state, plan.auto)
        results = known_results ++ auto_results
        broadcast_tools(state, known_calls ++ plan.auto, known_results ++ auto_results)
        state = complete_round(state, calls, results)
        finish_round(state)
      else
        # SOME call needs a human. The exchange is appended atomically
        # only once the whole round is decided, so nothing half-formed
        # ever reaches the wire. The auto/denied results computed now
        # are carried in state across the pause (and a resume) instead.
        auto_results = execute_tools(state, plan.auto)

        state = %{
          state
          | status: :interrupted,
            pending_tool_calls: plan.pending,
            pending_round_calls: calls,
            pending_round_results: known_results ++ auto_results
        }

        broadcast_tools(state, known_calls ++ plan.auto, known_results ++ auto_results)
        broadcast(state, {:status_changed, :interrupted, plan.pending})
        persist(state)
        {state, {:ok, state}}
      end
    end
  end

  # Gate-side refusals are logged with their id and reason so a live
  # failure is traceable.
  defp log_refusal(call, message) do
    {id, _, _} = ToolCall.normalize(call)
    Logger.warning("#{message}: #{inspect(id)}")
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
    ToolRunner.execute(state.id, tools, calls)
  end

  defp broadcast_tools(state, calls, results) do
    by_id = Map.new(results, &{&1.id, &1.content})

    Enum.each(calls, fn call ->
      {id, name, _args} = ToolCall.normalize(call)
      content = Map.get(by_id, id, "")
      broadcast(state, {:tool_executed, name, content})
    end)
  end

  # The registry narrowed by the policy (enabled whitelist + agent
  # disallowedTools) — see Session.ToolRunner.
  defp current_tools(state), do: ToolRunner.tools(state.policy, tool_scope(state))

  defp tool_scope(state), do: ToolRunner.scope(state.scope_root, state.mounts)

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

  defp call_llm(state) do
    with {:ok, model_input, base_opts} <-
           Request.build(effective_model(state), state.provider_config) do
      opts = Keyword.put(base_opts, :tools, current_tools(state))

      with {:ok, stream_response} <-
             ReqLLM.stream_text(model_input, sanitize_context(state.context), opts) do
        events = ReqLLM.StreamResponse.events(stream_response)

        # Hand the active stream's hard-cancel to the interrupt
        # coordinator: a stop request then closes the underlying
        # ReqLLM.StreamResponse, which cancels the HTTP work and
        # releases the session's blocked `next` call — the only way to
        # stop a reasoning-only stream that never emits another delta.
        Interrupt.register(state.id, fn -> ReqLLM.StreamResponse.close(stream_response) end)

        # consume_stream throws {:stream_error, ...} on stream failures
        # and returns {:interrupted, text} when the user stops the turn.
        # Catch the throw HERE: a transport error is a failed turn, an
        # interrupt is a finished (partial) turn — neither may crash the
        # session (the GenServer used to terminate on this path — found
        # in the 4a live smoke test).
        try do
          case consume_stream(events, state.id) do
            {:interrupted, partial} ->
              {:interrupted, partial}

            {text, tool_calls} ->
              # real token accounting (sidebar, token-based compaction):
              # the metadata task resolves after the stream is fully consumed
              usage = ReqLLM.StreamResponse.usage(stream_response)

              {:ok,
               %{type: classify(tool_calls), text: text, tool_calls: tool_calls, usage: usage}}
          end
        catch
          {:stream_error, error} -> {:error, {:stream_error, error}}
        after
          Interrupt.unregister(state.id)
        end
      end
    end
  end

  @doc false
  def consume_stream(events, session_id) do
    partial_key = {__MODULE__, :partial, session_id}
    Process.put(partial_key, "")

    try do
      events
      |> Enum.reduce_while({:streaming, "", []}, fn event, acc ->
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

  defp interrupt_result({:interrupted, text, _calls}, _session_id), do: {:interrupted, text}

  defp interrupt_result({:streaming, text, calls}, session_id) do
    # A hard cancel (Interrupt fires StreamResponse.close) empties the
    # provider queue and ends the stream with a plain `:halt` — no
    # further event reaches interrupt_check. Classify that as an
    # interrupt too, so the partial answer is kept instead of looking
    # like a clean finish.
    if Interrupt.requested?(session_id) do
      {:interrupted, text}
    else
      {text, Enum.reverse(calls)}
    end
  end

  # Broadcast the event's payload and fold it into the accumulator. The
  # flag check lives in interrupt_check/2 applied after EVERY event (not
  # per clause): a non-delta event after a hard cancel must also halt, or
  # the next pull would hit the already-stopped StreamServer and exit.
  defp handle_event(%{type: :text_delta, data: delta}, {:streaming, acc, calls}, session_id, key) do
    broadcast_text(session_id, delta)
    partial = acc <> delta
    Process.put(key, partial)
    {:streaming, partial, calls}
  end

  defp handle_event(
         %{type: :reasoning_delta, data: delta},
         {:streaming, acc, calls},
         session_id,
         key
       ) do
    broadcast_reasoning(session_id, delta)
    Process.put(key, acc)
    {:streaming, acc, calls}
  end

  defp handle_event(%{type: :tool_call, data: call}, {:streaming, acc, calls}, _session_id, _key) do
    {:streaming, acc, [call | calls]}
  end

  defp handle_event(%{type: :error, data: error}, _acc, _session_id, _key) do
    throw({:stream_error, error})
  end

  defp handle_event(_event, acc, _session_id, _key), do: acc

  # The user's stop request lands in the coordinator's ETS flag
  # (`Interrupt.request/1` cannot GenServer.call the session — it is busy
  # consuming this very stream). Checked after every stream event; stop
  # early keeping the partial text as the turn's answer (opencode esc
  # parity).
  defp interrupt_check({:streaming, acc, calls}, session_id) do
    if Interrupt.requested?(session_id) do
      {:halt, {:interrupted, acc, calls}}
    else
      {:cont, {:streaming, acc, calls}}
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
  def add_usage(state, usage) when is_map(usage) do
    prev = state.usage || %{input_tokens: 0, output_tokens: 0, cost: nil}

    # a nil/zero input count (interrupted or error turn, provider usage
    # event missing) must NOT clobber the honest count from the last
    # complete turn — a zero here silently re-arms the chars-based
    # compaction fallback on a fat context (found live: session
    # resumed, compaction fired at 212K chars despite the sidebar
    # showing 58.3k)
    last_in =
      case usage[:input_tokens] do
        n when is_integer(n) and n > 0 -> n
        _ -> Map.get(prev, :last_input_tokens, 0)
      end

    next = %{
      input_tokens: Map.get(prev, :input_tokens, 0) + (usage[:input_tokens] || 0),
      output_tokens: Map.get(prev, :output_tokens, 0) + (usage[:output_tokens] || 0),
      # the LAST turn's input = the context size the provider actually
      # saw — the honest token-based compaction measure (a chars-based
      # estimate drifts; the provider's own count is ground truth)
      last_input_tokens: last_in,
      cost: sum_cost(prev[:cost], usage[:total_cost])
    }

    state = %{state | usage: next}
    broadcast(state, {:usage_updated, next})
    state
  end

  def add_usage(state, nil), do: state

  defp sum_cost(nil, nil), do: nil
  defp sum_cost(a, b), do: (a || 0.0) + (b || 0.0)

  defp complete_turn(state, text) do
    context =
      state.context
      |> Context.append(ReqLLM.Context.assistant(text))

    state = %{state | context: context, status: :idle}
    broadcast(state, {:llm_message, text})
    broadcast(state, {:status_changed, :idle})
    persist(state)
    state
  end

  # Compaction is delegated to `CodingAgent.Core.Session.Compactor`
  # (trigger decision, summarize task, backoff); nothing of it lives
  # here — the loop only asks "should the context shrink?" and gets
  # {state, changed?} back.

  defp fail_turn(state, reason) do
    # the turn is over in every branch from here — drop any stale
    # user-interrupt flag so the NEXT turn starts clean
    drop_interrupt(state)
    state = %{state | status: :error, last_error: reason}
    broadcast(state, {:status_changed, :error, reason})
    persist(state)
    state
  end

  # turn-end cleanup: the stop flag is per-turn, never carries over
  defp drop_interrupt(state) do
    Interrupt.clear(state.id)
    state
  end

  # Slice 4a: every turn boundary leaves a persisted snapshot.  # Slice 4a: every turn boundary leaves a persisted snapshot. A crash
  # mid-turn loses at most the current turn — the previous boundary is
  # on disk. Failures are logged, never raised: an unwritable disk
  # must not kill a working session.
  #
  # Runtime-only fields are stripped before the write: worker refs and
  # the queue are process-local, and the test seam is a closure that
  # must never be serialized (Store.restore clears them too, belt and
  # braces for snapshots written by an older build).
  defp persist(state) do
    case state |> worker_snapshot() |> strip_runner() |> Store.save() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("session persist failed: #{inspect(reason)}")
    end

    state
  end

  defp strip_runner(state), do: %{state | turn_runner: nil}

  # -- Infrastructure ---------------------------------------------------------

  defp broadcast_reasoning(session_id, delta),
    do: Events.publish(session_id, {:reasoning_deltas, delta})

  defp broadcast_text(session_id, delta),
    do: Events.publish(session_id, {:llm_deltas, delta})

  defp broadcast(state, event), do: Events.publish(state.id, event)
end
