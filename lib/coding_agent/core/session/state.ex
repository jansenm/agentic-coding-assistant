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
    mounts: %{rw: [], ro: [], hide: []},
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
    # compaction trigger); cost only when the provider prices it
    usage: %{input_tokens: 0, output_tokens: 0, cost: nil},
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
    compaction_backoff: 0
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
          usage: map(),
          compaction_warned: boolean(),
          compaction_backoff: non_neg_integer()
        }

  @doc "Builds a new session state."
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end
end
