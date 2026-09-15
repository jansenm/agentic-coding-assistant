defmodule CodingAgent.Core.Session.Compactor.TaskSupervisor do
  @moduledoc """
  Supervisor for compaction summarize tasks.

  The summarize call runs third-party code (req_llm, provider
  adapters). The task MUST NOT be linked to the session process: a
  crash inside the provider stack would take the session down with it
  before `Task.yield/2` could observe anything (verified live: a
  raising `Task.async/1` body kills the linked caller). Under this
  supervisor (`async_nolink`) the crash is contained here and surfaces
  in the session as `{:exit, reason}` — one more failure mode that
  degrades (keep the context, back off) instead of killing the turn.
  """

  # Task.Supervisor has no __using__; init via the Supervisor behaviour.
  # :permanent under the app supervisor — if it cannot start, the app
  # must not come up half-ready (same fail-closed discipline as the
  # permission loader).
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, nil, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(_init_arg) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
