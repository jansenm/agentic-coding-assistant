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
    subscribers: [],
    tool_rounds: 0,
    test_mode: false,
    # cumulative usage across the session (sidebar + token-based
    # compaction trigger); cost only when the provider prices it. The
    # shape lives in Core.Session.Usage (P3: one home for the defaults
    # and last_input_tokens semantics).
    usage: CodingAgent.Core.Session.Usage.new(),
    # set once the 80%-of-trigger warning has been broadcast (once,
    # not every turn)
    compaction_warned: false,
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
    turn_runner: nil
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
          pending_tool_calls: [map()],
          pending_round_calls: [map()],
          pending_round_results: [map()],
          subscribers: [reference()],
          tool_rounds: non_neg_integer(),
          test_mode: boolean(),
          turn_agents: [String.t() | nil],
          usage: CodingAgent.Core.Session.Usage.t(),
          compaction_warned: boolean(),
          compaction_backoff: non_neg_integer(),
          worker_ref: reference() | nil,
          worker_from: GenServer.from() | nil,
          queued_calls: [tuple()],
          pending_agent: term(),
          pending_model: term(),
          turn_runner: (State.t() -> {State.t(), term()}) | nil
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
      status: idle_or_interrupted(state),
      # runtime guard counter: a snapshot saved with tool_rounds 25 (the
      # old never-reset bug) resurrected as 25, so resuming and
      # approving a pending call died instantly at the gate
      tool_rounds: 0,
      # usage heals a legacy map into the struct (wire-compatible)
      usage: CodingAgent.Core.Session.Usage.from_map(Map.get(state, :usage)),
      compaction_warned: Map.get(state, :compaction_warned, false),
      compaction_backoff: Map.get(state, :compaction_backoff, 0),
      pending_round_calls: Map.get(state, :pending_round_calls, []),
      pending_round_results: Map.get(state, :pending_round_results, []),
      # per-turn agent attribution (old snapshots lack it)
      turn_agents: Map.get(state, :turn_agents, []),
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
