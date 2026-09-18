defmodule CodingAgent.Core.Session.TurnTaskSupervisor do
  @moduledoc """
  Supervisor for the session's turn workers.

  A turn is one long, blocking stretch of I/O: provider streaming, tool
  execution and the compaction summarize call. Running it inline in the
  session GenServer froze the whole mailbox for the turn's duration
  (found live: Tab hung the UI while the agent streamed). The session
  now hands the blocking loop to a task under THIS supervisor and stays
  responsive — `state/1`, `set_agent/2`, `interrupt/1` and `decide/2`
  are all answered while the turn streams.

  The task is started with `async_nolink`: it runs third-party code
  (req_llm, provider adapters, shell), and a crash there must surface
  in the session as a `:DOWN` it can turn into a failed turn — never
  take the state-owning process down with it. `:temporary` (the
  default) means a dead worker is not restarted, which is exactly right
  for a one-shot turn.

  This is a thin named wrapper over `Task.Supervisor` so call sites and
  tests have one stable name; `Task.Supervisor` itself has no
  `__using__`, so `start_link/1` delegates.
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Task.Supervisor.start_link(Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end
end
