defmodule CodingAgent.TuiCase do
  @moduledoc """
  Shared harness for TUI tests: deterministic synchronization instead
  of `Process.sleep`.

  Three facts make the sleeps unnecessary:

  - `send/2` + `:sys.get_state/1` is a barrier: Erlang delivers
    messages per-sender in order, and `get_state` is a call, so it
    cannot be answered before an earlier `send` from the same process
    is handled. `sync/1` is therefore a fence, not a poll.
  - `ExRatatui.Runtime.inject_event/2` is a synchronous `GenServer.call`
    that runs the handler AND the render inside the call — after it
    returns, both `user_state` and the terminal buffer are current.
  - timer-driven UI transitions (`:__menu_timeout__`,
    `:__resize_poll__`) are plain `handle_info` clauses: a test can
    `fire/2` them instead of waiting the wall clock out.

  Cross-process work (the session broadcasting to the TUI, a `Task`
  that runs `Session.decide/2`) still needs `wait_until/2` — poll the
  condition, do not sleep a fixed amount.
  """

  @wait_interval 5
  @wait_timeout 2_000

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, async: unquote(Keyword.get(opts, :async, true))

      import CodingAgent.TuiCase
    end
  end

  @doc "The TUI's `user_state` — a barrier on the process mailbox."
  @spec sync(pid() | GenServer.server()) :: map()
  def sync(pid), do: :sys.get_state(pid).user_state

  @doc "The full runtime state (`user_state` + `terminal_ref`)."
  @spec runtime(pid() | GenServer.server()) :: map()
  def runtime(pid), do: :sys.get_state(pid)

  @doc "The rendered terminal buffer, split into lines."
  @spec buffer(pid() | GenServer.server()) :: [String.t()]
  def buffer(pid) do
    pid
    |> runtime()
    |> Map.fetch!(:terminal_ref)
    |> ExRatatui.get_buffer_content()
    |> String.split("\n")
  end

  @doc """
  Polls `fun` until it is truthy. Used for cross-process conditions
  (broadcasts, async tasks) that a mailbox fence cannot cover.
  """
  @spec wait_until((-> boolean()), keyword()) :: :ok
  def wait_until(fun, opts \\ []) do
    interval = Keyword.get(opts, :interval, @wait_interval)
    timeout = Keyword.get(opts, :timeout, @wait_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, interval, deadline)
  end

  defp do_wait_until(fun, interval, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "wait_until timed out after #{@wait_timeout}ms"
      end

      Process.sleep(interval)
      do_wait_until(fun, interval, deadline)
    end
  end

  @doc "Injects a key press event (synchronous: handler + render ran on return)."
  @spec key(pid(), String.t(), [String.t()]) :: :ok
  def key(pid, code, mods \\ []) do
    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{
      kind: "press",
      code: code,
      modifiers: mods
    })
  end

  @doc "Injects a left mouse click at (x, y)."
  @spec click(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  def click(pid, x, y) do
    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Mouse{
      kind: "down",
      button: "left",
      x: x,
      y: y
    })
  end

  @doc """
  Fires a timer-driven message the TUI would otherwise get on a wall
  clock, then fences: `fire(pid, :__menu_timeout__)`,
  `fire(pid, :__resize_poll__)`.
  """
  @spec fire(pid(), atom()) :: map()
  def fire(pid, msg) do
    send(pid, msg)
    sync(pid)
  end

  @doc """
  Fires the agent event directly (equivalent to a session broadcast).

  Streaming deltas DEFER their render (the stream throttle paints them on
  a timer), so a delta event also fires the render tick: tests assert on
  `buffer/1` immediately after `agent/2` and must see the painted frame.
  The tick is a plain `handle_info` clause, so this is deterministic, not
  a sleep.
  """
  @spec agent(pid(), tuple()) :: map()
  def agent(pid, event) do
    send(pid, {:agent, event})
    state = sync(pid)

    case event do
      {:llm_deltas, _} -> fire(pid, :__stream_render__)
      {:reasoning_deltas, _} -> fire(pid, :__stream_render__)
      _ -> state
    end
  end
end
