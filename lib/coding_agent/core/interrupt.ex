# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Interrupt do
  @moduledoc """
  User-stop coordination for running turns (opencode's esc) — in ONE
  place.

  ## Why a separate process + ETS

  A running turn keeps the session process inside its own
  `handle_call/3` (streaming, tool rounds, compaction), so the session
  never services its mailbox: a `send(session_pid, :interrupt)` would
  only be read after the turn ends. The stop signal therefore has to
  live OUTSIDE the session process.

  The flag is written from the TUI process while the session is busy, so
  the table is owned by this long-lived supervised GenServer — a lazily
  created table would be owned by whichever process first touched it and
  vanish with it. Reads happen on the token-frequency streaming path, so
  `requested?/1` is a direct `:ets.lookup` (no round-trip, and it keeps
  working even if this process were wedged). The table is `:protected`:
  only the owner writes, everyone reads.

  ## Two-tier stop

  - **Cooperative**: `requested?/1` is checked between stream events
    (text AND reasoning) and at loop boundaries; the partial answer is
    kept (opencode parity).
  - **Hard**: while a stream is active the session `register/2`s a
    closure that closes the underlying `ReqLLM.StreamResponse`;
    `request/1` fires it in a linked-free spawned process, killing the
    HTTP work and unblocking the session even if no further delta would
    ever arrive (the reasoning-only stall).
  """

  use GenServer

  require Logger

  @name CodingAgent.Interrupts

  @typedoc "Session id whose turn is being stopped."
  @type id :: String.t()

  @typedoc "Closure that closes the active provider stream."
  @type cancel_fun :: (-> any())

  @type snapshot :: %{
          requested?: boolean(),
          at: integer() | nil,
          cancelling?: boolean()
        }

  # -- Client -----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Requests the running turn for `id` to stop: raises the flag and fires
  the registered stream cancel closure (if a stream is active). Safe to
  call at any time and idempotent.
  """
  @spec request(id()) :: :ok
  def request(id), do: GenServer.call(__MODULE__, {:request, id})

  @doc "Clears the flag and any registered cancel handle (turn-end reset)."
  @spec clear(id()) :: :ok
  def clear(id), do: GenServer.call(__MODULE__, {:clear, id})

  @doc """
  Registers the cancel closure for the currently active stream. Called
  by the session right after the stream is created and unregistered when
  the stream ends.
  """
  @spec register(id(), cancel_fun()) :: :ok
  def register(id, fun) when is_function(fun, 0),
    do: GenServer.call(__MODULE__, {:register, id, fun})

  @doc "Drops the active-stream cancel handle (stream ended/aborted)."
  @spec unregister(id()) :: :ok
  def unregister(id), do: GenServer.call(__MODULE__, {:unregister, id})

  @doc """
  Cooperative read for the hot streaming path: a direct ETS lookup, no
  message to this process. Returns false when the app tree is absent (a
  bare test) rather than raising.
  """
  @spec requested?(id()) :: boolean()
  def requested?(id) do
    case :ets.whereis(@name) do
      :undefined ->
        false

      _ ->
        case :ets.lookup(@name, id) do
          [{^id, %{requested?: true}}] -> true
          _ -> false
        end
    end
  end

  @doc "Observability snapshot for the TUI/tests."
  @spec snapshot(id()) :: snapshot()
  def snapshot(id), do: GenServer.call(__MODULE__, {:snapshot, id})

  # -- Server -----------------------------------------------------------------

  @impl true
  def init(nil) do
    if :ets.whereis(@name) == :undefined do
      :ets.new(@name, [:set, :named_table, :protected, read_concurrency: true])
    end

    {:ok, %{cancels: %{}}}
  end

  @impl true
  def handle_call({:request, id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    :ets.insert(@name, {id, %{requested?: true, at: now}})
    fire_cancel(Map.get(state.cancels, id))
    {:reply, :ok, state}
  end

  def handle_call({:clear, id}, _from, state) do
    :ets.delete(@name, id)
    {:reply, :ok, %{state | cancels: Map.delete(state.cancels, id)}}
  end

  def handle_call({:register, id, fun}, _from, state) do
    {:reply, :ok, %{state | cancels: Map.put(state.cancels, id, fun)}}
  end

  def handle_call({:unregister, id}, _from, state) do
    {:reply, :ok, %{state | cancels: Map.delete(state.cancels, id)}}
  end

  def handle_call({:snapshot, id}, _from, state) do
    row =
      case :ets.lookup(@name, id) do
        [{^id, data}] -> data
        _ -> %{requested?: false, at: nil}
      end

    {:reply,
     %{
       requested?: Map.get(row, :requested?, false),
       at: Map.get(row, :at),
       cancelling?: Map.has_key?(state.cancels, id)
     }, state}
  end

  # Fire the cancel in a plain spawned process: the TUI must never block
  # on a wedged StreamServer, and a crash in provider-stack cleanup must
  # not take the caller down. All failures degrade to a debug line —
  # `request/1` already returns; the flag is the source of truth.
  defp fire_cancel(nil), do: :ok

  defp fire_cancel(fun) do
    spawn(fn ->
      try do
        fun.()
      rescue
        e -> Logger.debug("interrupt cancel raised: #{Exception.message(e)}")
      catch
        kind, reason -> Logger.debug("interrupt cancel #{kind}: #{inspect(reason)}")
      end
    end)

    :ok
  end
end
