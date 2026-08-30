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
    pending_tool_calls: [],
    subscribers: []
  ]

  @type status :: :idle | :running | :interrupted | :error

  @type t :: %__MODULE__{
          id: String.t(),
          context: ReqLLM.Context.t(),
          model: String.t() | nil,
          status: status(),
          last_error: term() | nil,
          pending_tool_calls: [map()],
          subscribers: [reference()]
        }

  @doc "Builds a new session state."
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end
end
