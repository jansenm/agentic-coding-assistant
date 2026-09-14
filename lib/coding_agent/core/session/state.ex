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
    pending_tool_calls: [],
    subscribers: [],
    tool_rounds: 0,
    test_mode: false,
    # cumulative usage across the session (sidebar + token-based
    # compaction trigger); cost only when the provider prices it
    usage: %{input_tokens: 0, output_tokens: 0, cost: nil},
    # set once the 80%-of-trigger warning has been broadcast (once,
    # not every turn)
    compaction_warned: false,
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
          pending_tool_calls: [map()],
          subscribers: [reference()],
          tool_rounds: non_neg_integer(),
          test_mode: boolean()
        }

  @doc "Builds a new session state."
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end
end
