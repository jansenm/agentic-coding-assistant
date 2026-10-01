defmodule CodingAgent.Core.Session.State do
  @moduledoc """
  Plain-data session state (ADR 003: everything is data, so a session
  can be persisted and resumed at any loop boundary).
  """

  @enforce_keys [:id, :context, :model, :status]
  defstruct [
    :id,
    :context,
    :model,
    :status,
    :last_error,
    :scope_root,
    :policy,
    provider_config: %{},
    # The resolved agent definition (ADR 017), or nil when the session
    # runs without one. The UI reads name/model for the two slots (ADR
    # 018); the policy already carries the definition's permission layer.
    agent: nil,
    # The policy and system prompt BEFORE any agent layer was applied.
    # Switching agents (set_agent/2) recomputes from these, so applying a
    # second definition never compounds with the first (apply_agent is
    # narrowing, not idempotent).
    base_policy: nil,
    base_prompt: nil,
    # A caller-supplied system prompt that OVERRIDES the model-selected
    # framework prompt (ADR 024). Kept here (not just in the start opts)
    # so a model switch recomposes from it, and a resume carries it.
    # nil means "use the per-model prompt file".
    prompt_override: nil,
    # The model's todo list (ADR 031): a list of
    # `%{"content" => ..., "status" => "pending" | "in_progress" | "completed"}`
    # (maps with string keys, as they arrive from the tool arguments).
    # `todowrite` REPLACES the whole list each call; the session never
    # edits it. Injected into every request (Prompt.with_todos/2) and
    # rendered by the TUI sidebar. Durable: it round-trips in the store's
    # state BLOB, so there is no migration.
    todos: [],
    # Sandbox mount schema (ADR 015): %{rw: [...], ro: [...], hide: [...]}.
    # Read from UserConfig layers at start (rw only from shipped+global,
    # never the project layer). Empty means "no extra mounts".
    mounts: CodingAgent.Core.Sandbox.Mounts.empty(),
    pending_tool_calls: [],
    # The current round's tool exchange is appended ATOMICALLY: while any
    # call of the round waits at the gate, nothing goes on the wire yet.
    # These carry the already-known half across the pause — every call of
    # the round (so the assistant message can declare them all, in final
    # edited form) and the results already computed (auto-executed,
    # blacklist-denied, policy-denied). Without them a mixed round
    # appended bare tool results with no declaring assistant message,
    # and a resumed round lost the auto results.
    pending_round_calls: [],
    pending_round_results: [],
    # Parked at the tool-round budget (ADR 025): %{calls, rounds} when an
    # INTERACTIVE driver was asked "continue or stop?" and has not answered
    # yet. nil otherwise. `calls` is the round that tripped the budget —
    # "continue" executes it under a fresh budget; "stop" wraps up.
    budget_pause: nil,
    # Parked at a detected doom loop (three consecutive identical calls,
    # ADR 026): %{calls, tool} when the user was asked continue/reject.
    # nil otherwise.
    doom_pause: nil,
    # Parked on a question the model asked (ADR 027): %{calls, questions}
    # while the human is answering. nil otherwise. The whole round is held
    # so the exchange stays atomic.
    question_pause: nil,
    # File checkpoints for /undo (ADR 036), newest LAST: a list of
    # `%{ref, commit, tree, staged_tree, untracked, at}` (see
    # `CodingAgent.Core.Checkpoint.t/0`). A checkpoint is written before
    # every turn; `/undo` restores the newest and drops it, bounded by
    # `checkpoint_depth`. Durable (the store state BLOB), so a resumed
    # session can undo across a restart. Old snapshots heal to [].
    checkpoints: [],
    # Subagent seams (ADR 017/018). `depth` is 0 for a primary session and
    # 1 for a delegated child; depth 1 excludes the `task` tool (bounded
    # fan-out). `subagents` is what a `task` call may delegate to, as
    # `%{name, description}` — the description is the delegation hint the
    # tool advertises. `persist?` is false for a child: its summary is the
    # durable record (in the parent), not a picker entry of its own.
    depth: 0,
    subagents: [],
    persist?: true,
    # The last few tool-call ROUND signatures of the CURRENT turn, newest
    # last — each is a sorted list of {name, args}. The window the
    # doom-loop guard looks at (ADR 026). Runtime-only: reset per turn
    # and never persisted.
    recent_calls: [],
    # Whether a driver (the TUI) can answer a mid-turn question at all. A
    # non-interactive driver (future headless mode, a test) gets the
    # automatic wrap-up instead of a pause nobody can resolve.
    interactive: false,
    subscribers: [],
    tool_rounds: 0,
    # The session-level tool-round budget, resolved once at init from the
    # layered config.toml (`max_tool_rounds`, project over global), with
    # the app-env default as fallback. An agent definition's `max_turns`
    # overrides it per turn (`tool_budget/1`, ADR 025). nil means "use the
    # app-env default" — a directly-constructed State (tests) need not set it.
    max_tool_rounds: nil,
    # The session's reasoning effort (ADR 029): req_llm's canonical
    # `:reasoning_effort` atom (`:none | :minimal | ... | :default`) on
    # every request, or nil for the provider default. Resolved once at
    # init from the layered config.toml (project over global) or the app
    # env; like `max_tool_rounds`, a resume re-resolves it from config
    # rather than trusting the snapshot.
    reasoning_effort: nil,
    # The model context window and the two compaction limits (ADR 037),
    # resolved once at init from config (a layered `context_window`, the
    # catalog, the app-env fallback). Carried on the state so the
    # sidebar, the warning and the decision read the SAME numbers (ADR
    # 029: the display must not re-derive what the decision uses). nil
    # on a hand-built state — the Compactor falls back to Config.
    context_window: nil,
    compaction_soft_limit: nil,
    compaction_hard_limit: nil,
    test_mode: false,
    # cumulative usage across the session (sidebar + token-based
    # compaction trigger); cost only when the provider prices it. The
    # shape lives in Core.Session.Usage (P3: one home for the defaults
    # and last_input_tokens semantics).
    usage: CodingAgent.Core.Session.Usage.new(),
    # set once the 80%-of-trigger warning has been broadcast (once,
    # not every turn)
    compaction_warned: false,
    # set once a checkpoint failure has been surfaced as a transcript note
    # (ADR 036; review F3): a snapshot that keeps failing (e.g. a linked
    # worktree whose git dir is not writable through the sandbox) must not
    # stay silent, or `/undo` reads as working. Warned once per session,
    # not per turn.
    checkpoint_warned: false,
    # ONE agent name (or nil) per USER turn, in execution order — the
    # agent that answered that turn. Persisted with the session so a
    # resumed/old session can attribute every user message and its
    # assistant reply to the agent that handled it (the UI's footer).
    # Synthetic user messages (compaction summaries) are NOT turns and
    # are never recorded here.
    turn_agents: [],
    # consecutive compaction failures: with 0..backoff_left, compaction
    # is SKIPPED (found live: GLM cloud needs minutes for an 80K-char
    # summary call and fails with reason:"timeout" — retrying every
    # turn meant 2+ minutes of dead silence before every real turn)
    compaction_backoff: 0,
    # -- runtime-only turn bookkeeping (never persisted; cleared on load).
    # The session process stays responsive while a turn streams by
    # running the blocking loop in a separate worker task. It holds only
    # the mailbox-level handles, never the worker's live state.
    #
    # the in-flight worker's monitor ref, or nil when no turn is running
    worker_ref: nil,
    # the GenServer.from of the caller whose run/decide is deferred until
    # the worker reports back (GenServer.reply/2)
    worker_from: nil,
    # calls that arrived while a turn was already in flight, in arrival
    # order: {:run, from, prompt} | {:decide, from, decisions}. They run
    # once the current worker finishes, preserving the old mailbox
    # serialization without blocking the session.
    queued_calls: [],
    # agent/model switches requested mid-turn. They take effect at the
    # turn boundary (ADR 018: a running turn keeps its own agent), so
    # they are held here and applied when the worker's state merges back.
    # :none = nothing pending (nil is a meaningful "clear the agent").
    pending_agent: :none,
    pending_model: :none,
    # test-only seam: replaces the worker's blocking body, so a test can
    # hold a turn "in flight" without touching a provider. nil in
    # production. Runtime-only.
    turn_runner: nil,
    # test-only seam: replaces a CHILD session's blocking body (the
    # subagent path), so a test can exercise delegation without a provider.
    # nil in production. Runtime-only.
    subagent_runner: nil,
    # test-only seam: replaces the idle (soft-limit) compaction body
    # (ADR 037), so a test can exercise the background pass and its
    # fingerprint guard without a provider. nil in production.
    # Runtime-only.
    idle_compaction_runner: nil,
    # The in-flight IDLE (soft-limit) compaction task (ADR 037) and the
    # context fingerprint captured when it started. The soft pass runs in
    # a background task after a turn ends; if the context changed while it
    # ran (a new turn started), the result is discarded rather than
    # applied to a context it no longer matches. Runtime-only.
    idle_compaction_ref: nil,
    idle_compaction_fp: nil
  ]

  @type status :: :idle | :running | :interrupted | :error

  @type t :: %__MODULE__{
          id: String.t(),
          context: ReqLLM.Context.t(),
          model: String.t() | nil,
          status: status(),
          last_error: term() | nil,
          scope_root: String.t() | nil,
          policy: CodingAgent.Core.Permissions.t() | nil,
          provider_config: %{String.t() => term()} | nil,
          mounts: CodingAgent.Core.Sandbox.Mounts.t(),
          agent: CodingAgent.Core.Agent.t() | nil,
          base_policy: CodingAgent.Core.Permissions.t() | nil,
          base_prompt: String.t() | nil,
          prompt_override: String.t() | nil,
          todos: [map()],
          pending_tool_calls: [map()],
          pending_round_calls: [map()],
          pending_round_results: [map()],
          budget_pause: map() | nil,
          doom_pause: map() | nil,
          question_pause: map() | nil,
          depth: non_neg_integer(),
          subagents: [%{name: String.t(), description: String.t() | nil}],
          persist?: boolean(),
          recent_calls: [[{String.t(), map()}]],
          interactive: boolean(),
          subscribers: [reference()],
          tool_rounds: non_neg_integer(),
          max_tool_rounds: pos_integer() | nil,
          reasoning_effort: atom() | nil,
          context_window: pos_integer() | nil,
          compaction_soft_limit: pos_integer() | nil,
          compaction_hard_limit: pos_integer() | nil,
          test_mode: boolean(),
          turn_agents: [String.t() | nil],
          usage: CodingAgent.Core.Session.Usage.t(),
          compaction_warned: boolean(),
          checkpoint_warned: boolean(),
          compaction_backoff: non_neg_integer(),
          worker_ref: reference() | nil,
          worker_from: GenServer.from() | nil,
          queued_calls: [tuple()],
          pending_agent: term(),
          pending_model: term(),
          turn_runner: (State.t() -> {State.t(), term()}) | nil,
          subagent_runner: (State.t() -> {State.t(), term()}) | nil,
          idle_compaction_runner: (State.t() -> {State.t(), boolean()}) | nil,
          idle_compaction_ref: reference() | nil,
          idle_compaction_fp: term()
        }

  @doc "Builds a new session state."
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end

  # The model a turn actually uses: the agent definition's model when it
  # sets one, otherwise the session's model (config / model menu /
  # resume). ADR 017 allows a definition to pin its own model; this is
  # where that becomes real (the field was parsed but unused).
  @doc """
  The model a turn actually uses: the agent definition's model when set,
  otherwise the session's model.
  """
  @spec effective_model(t()) :: String.t() | nil
  def effective_model(%__MODULE__{agent: %{model: model}}) when is_binary(model) and model != "",
    do: model

  def effective_model(%__MODULE__{model: model}), do: model

  @doc """
  The tool-round budget for a turn (ADR 025): an agent definition's
  ``max_turns`` when it sets one, otherwise the session's resolved
  ``max_tool_rounds``, otherwise `nil` (the caller falls back to the
  app-env default). Mirrors `effective_model/1` so the same definition
  that pins its model may also pin its budget.
  """
  @spec tool_budget(t()) :: pos_integer() | nil
  def tool_budget(%__MODULE__{agent: %{max_turns: n}}) when is_integer(n) and n > 0, do: n

  def tool_budget(%__MODULE__{max_tool_rounds: n}) when is_integer(n) and n > 0, do: n

  def tool_budget(_), do: nil

  @doc """
  Rebuilds a decoded snapshot into a complete `%State{}`, healing
  snapshots written by older builds. This is the persistence-format
  knowledge that used to live in `Store`, which should not know the
  shape of `State`'s nested structs.

  Two hazards, both found live:

  1. `struct!/1` (map form) stopped applying struct defaults in Elixir
     1.20 — a key the snapshot lacks stays missing and any access raises
     KeyError ("key :base_policy not found"). Use `struct!/2`
     (module + map) so every field the snapshot predates gets its
     default.
  2. Nested structs are the SAME trap one level down: an old snapshot
     carries a `%Permissions{}` without the later `:disabled` field, so
     Tab (`apply_agent/2` reading `policy.disabled`) crashed on load.

  Unknown keys are dropped FIRST: a NEWER snapshot (same
  format_version) carries fields this build does not know, and
  `struct!/2` raises KeyError on them. An old binary must fail closed,
  not crash.
  """
  @spec restore(term()) :: {:ok, t()} | {:error, term()}
  def restore(%__MODULE__{} = state) do
    overrides = %{
      # runtime-only fields must not resurrect
      subscribers: [],
      # turn bookkeeping is process-local: a snapshot must never carry a
      # stale worker ref/queue back into a fresh process
      worker_ref: nil,
      worker_from: nil,
      queued_calls: [],
      pending_agent: :none,
      pending_model: :none,
      turn_runner: nil,
      subagent_runner: nil,
      # the idle-compaction task is process-local (ADR 037): its ref and
      # fingerprint must not resurrect, and the test seam is a closure
      idle_compaction_runner: nil,
      idle_compaction_ref: nil,
      idle_compaction_fp: nil,
      status: idle_or_interrupted(state),
      # runtime guard counter: a snapshot saved with tool_rounds 25 (the
      # old never-reset bug) resurrected as 25, so resuming and
      # approving a pending call died instantly at the gate
      tool_rounds: 0,
      # usage heals a legacy map into the struct (wire-compatible)
      usage: CodingAgent.Core.Session.Usage.from_map(Map.get(state, :usage)),
      compaction_warned: Map.get(state, :compaction_warned, false),
      checkpoint_warned: Map.get(state, :checkpoint_warned, false),
      compaction_backoff: Map.get(state, :compaction_backoff, 0),
      pending_round_calls: Map.get(state, :pending_round_calls, []),
      pending_round_results: Map.get(state, :pending_round_results, []),
      # A budget pause is durable like a gate pause: the round it carries
      # and the question survive, so a resumed session re-offers the
      # dialog instead of silently dropping the interrupted round.
      budget_pause: Map.get(state, :budget_pause),
      # a doom-loop pause is durable the same way (ADR 026)
      doom_pause: Map.get(state, :doom_pause),
      # a question pause is durable too (ADR 027)
      question_pause: Map.get(state, :question_pause),
      # the detection window is per-turn runtime state, never persisted
      recent_calls: [],
      # the interactivity of a live driver is not persisted state
      interactive: false,
      # per-turn agent attribution (old snapshots lack it)
      turn_agents: Map.get(state, :turn_agents, []),
      # the model's todo list (ADR 031); old snapshots lack it
      todos: Map.get(state, :todos, []),
      # file checkpoints (ADR 036); old snapshots lack them
      checkpoints: Map.get(state, :checkpoints, []),
      # the compaction window/limits (ADR 037) are re-resolved at init
      # (like max_tool_rounds/reasoning_effort), never trusted from the
      # snapshot: clear them so a directly-loaded state falls back to
      # Config and a resumed one gets the freshly resolved numbers.
      context_window: nil,
      compaction_soft_limit: nil,
      compaction_hard_limit: nil,
      # nested structs: heal the Elixir 1.20 missing-default trap one
      # level down (see above)
      policy: heal(state.policy, CodingAgent.Core.Permissions),
      base_policy: heal(Map.get(state, :base_policy), CodingAgent.Core.Permissions),
      agent: heal(Map.get(state, :agent), CodingAgent.Core.Agent),
      mounts: heal_mounts(Map.get(state, :mounts)),
      provider_config: Map.get(state, :provider_config) || %{}
    }

    known =
      state
      |> Map.take(Map.keys(__struct__()))
      |> Map.drop([:__struct__])

    {:ok, struct!(__MODULE__, Map.merge(known, overrides))}
  rescue
    # A snapshot whose shape we cannot reconcile (e.g. a required key is
    # a foreign struct) is a load failure, not a crash: the caller shows
    # it and offers a fresh start.
    e -> {:error, {:bad_session_state, Exception.message(e)}}
  end

  def restore(other), do: {:error, {:bad_session_state, other}}

  # running/error sessions come back idle: the turn that was in flight is
  # gone with the process. A gate-parked session stays parked.
  defp idle_or_interrupted(%{status: :interrupted}), do: :interrupted
  defp idle_or_interrupted(_), do: :idle

  # Fill a nested struct's defaults when it lacks later fields. nil
  # stays nil (no agent / no base policy is a legitimate state).
  defp heal(nil, _mod), do: nil

  defp heal(%mod{} = nested, mod) do
    fields =
      nested
      |> Map.take(Map.keys(mod.__struct__()))
      |> Map.drop([:__struct__])

    struct!(mod, fields)
  end

  defp heal(other, _mod), do: other

  # mounts is a plain map (not a struct); a key added later must not
  # crash the sandbox resolver.
  defp heal_mounts(m) when is_map(m) do
    %{rw: Map.get(m, :rw, []), ro: Map.get(m, :ro, []), hide: Map.get(m, :hide, [])}
  end

  defp heal_mounts(_), do: CodingAgent.Core.Sandbox.Mounts.empty()
end
