defmodule CodingAgent.UI.TuiTest do
  use ExUnit.Case, async: false

  alias CodingAgent.UI.Tui
  alias ExRatatui.Runtime

  # The TUI app under test_mode: no real terminal, no real session
  # (mount skips Core when it cannot start; the render paths are what
  # 5a verifies). The status line + transcript rendering are the
  # dogfood item #1.

  describe "rendering" do
    test "status line shows idle + session id" do
      pid = start_supervised!({Tui, name: nil, test_mode: {80, 10}})

      state = :sys.get_state(pid).user_state
      assert state.status == :idle
      assert state.transcript == []
      assert state.session_id =~ "tui-"
    end

    test "streaming deltas accumulate in the delta buffer" do
      pid = start_supervised!({Tui, name: nil, test_mode: {80, 10}})

      send(pid, {:agent, {:llm_deltas, "Hel"}})
      send(pid, {:agent, {:llm_deltas, "lo"}})
      send(pid, {:agent, {:status_changed, :running}})

      wait_until(fn ->
        state = :sys.get_state(pid).user_state
        state.deltas == "Hello" and state.status == :running
      end)

      state = :sys.get_state(pid).user_state
      assert state.deltas == "Hello"
      assert state.status == :running
    end

    test "llm_message moves deltas into the transcript" do
      pid = start_supervised!({Tui, name: nil, test_mode: {80, 10}})

      send(pid, {:agent, {:llm_deltas, "answer text"}})
      send(pid, {:agent, {:llm_message, "answer text"}})
      send(pid, {:agent, {:tool_executed, "shell", "exit 0\n--- output ---\nstuff"}})

      wait_until(fn ->
        state = :sys.get_state(pid).user_state
        state.transcript != [] and length(state.transcript) == 2
      end)

      state = :sys.get_state(pid).user_state
      assert state.deltas == ""

      assert [
               {:assistant, "answer text"},
               {:tool, _id, "shell", content}
             ] = state.transcript

      assert content =~ "stuff"
    end

    test "q event stops the app" do
      pid = start_supervised!({Tui, name: nil, test_mode: {80, 10}})
      :ok = Runtime.inject_event(pid, %ExRatatui.Event.Key{code: "q", kind: "press"})

      wait_until(fn ->
        not Process.alive?(pid)
      end)

      refute Process.alive?(pid)
    end
  end

  defp wait_until(fun, tries \\ 50) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end

  describe "event delivery (5a regression: subscribe bug)" do
    # Found live: Session.subscribe registered the SESSION process on the
    # EventRegistry instead of the caller — the TUI (first real consumer)
    # received no events and the app hung on :running forever. The CLI
    # never noticed because run/2 returns the final state.

    test "the TUI process is actually registered on the event registry" do
      {:ok, pid} = Tui.start_link(name: nil, test_mode: {80, 10}, scope_root: File.cwd!())

      sid = :sys.get_state(pid).user_state.session_id
      subscribers = Registry.lookup(CodingAgent.EventRegistry, {:session_events, sid})
      assert pid in Enum.map(subscribers, fn {p, _} -> p end)
    end

    test "broadcast events reach the TUI and update state" do
      {:ok, pid} = Tui.start_link(name: nil, test_mode: {80, 10}, scope_root: File.cwd!())

      sid = :sys.get_state(pid).user_state.session_id

      Registry.dispatch(CodingAgent.EventRegistry, {:session_events, sid}, fn entries ->
        for {p, _} <- entries, do: send(p, {:agent, {:llm_message, "broadcast"}})
      end)

      wait_until(fn ->
        :sys.get_state(pid).user_state.transcript != []
      end)

      assert [{:assistant, "broadcast"}] = :sys.get_state(pid).user_state.transcript
    end
  end
end
