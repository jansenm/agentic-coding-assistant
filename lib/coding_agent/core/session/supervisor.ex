defmodule CodingAgent.Core.Session.Supervisor do
  @moduledoc """
  Starts sessions on demand under the application supervisor.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Starts a session with the given options; idempotent per session id."
  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    id = Keyword.fetch!(opts, :id)

    child = %{
      id: id,
      start: {CodingAgent.Core.Session, :start_link, [opts]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(__MODULE__, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
