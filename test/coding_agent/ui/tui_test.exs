defmodule CodingAgent.UI.TuiTest do
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.Tui
  alias ExRatatui.Runtime

  # The TUI app under test_mode: no real terminal, no real session
  # (mount skips Core when it cannot start; the render paths are what
  # 5a verifies). The status line + transcript rendering are the
  # dogfood item #1.

  describe "rendering" do
    test "status line shows idle + session id" do
      pid = start_supervised!({Tui, name: nil, test_mode: {80, 10}})

      state = sync(pid)
      assert state.status == :idle
      assert state.transcript == []
      assert state.session_id =~ "tui-"
    end

    test "streaming deltas accumulate in the delta buffer" do
      pid = start_supervised!({Tui, name: nil, test_mode: {80, 10}})

      send(pid, {:agent, {:llm_deltas, "Hel"}})
      send(pid, {:agent, {:llm_deltas, "lo"}})
      send(pid, {:agent, {:status_changed, :running}})

      state = sync(pid)
      assert state.deltas == "Hello"
      assert state.status == :running
    end

    test "llm_message moves deltas into the transcript" do
      pid = start_supervised!({Tui, name: nil, test_mode: {80, 10}})

      send(pid, {:agent, {:llm_deltas, "answer text"}})
      send(pid, {:agent, {:llm_message, "answer text"}})
      send(pid, {:agent, {:tool_executed, "shell", "exit 0\n--- output ---\nstuff"}})

      state = sync(pid)
      assert state.deltas == ""

      assert [
               {:assistant, "answer text"},
               {:tool, _id, "shell", content}
             ] = state.transcript

      assert content =~ "stuff"
    end

    test "abort (ctrl-c) stops the app" do
      pid = start_supervised!({Tui, name: nil, test_mode: {80, 10}})

      :ok =
        Runtime.inject_event(pid, %ExRatatui.Event.Key{
          code: "c",
          kind: "press",
          modifiers: ["ctrl"]
        })

      wait_until(fn -> not Process.alive?(pid) end)

      refute Process.alive?(pid)
    end
  end

  describe "event delivery (5a regression: subscribe bug)" do
    # Found live: Session.subscribe registered the SESSION process on the
    # EventRegistry instead of the caller — the TUI (first real consumer)
    # received no events and the app hung on :running forever. The CLI
    # never noticed because run/2 returns the final state.

    test "the TUI process is actually registered on the event registry" do
      {:ok, pid} = Tui.start_link(name: nil, test_mode: {80, 10}, scope_root: File.cwd!())

      sid = sync(pid).session_id
      subscribers = Registry.lookup(CodingAgent.EventRegistry, {:session_events, sid})
      assert pid in Enum.map(subscribers, fn {p, _} -> p end)
    end

    test "broadcast events reach the TUI and update state" do
      {:ok, pid} = Tui.start_link(name: nil, test_mode: {80, 10}, scope_root: File.cwd!())

      sid = sync(pid).session_id

      Registry.dispatch(CodingAgent.EventRegistry, {:session_events, sid}, fn entries ->
        for {p, _} <- entries, do: send(p, {:agent, {:llm_message, "broadcast"}})
      end)

      # the dispatch sent from THIS process, so the sync call is fenced
      # behind it (per-sender FIFO) — no polling needed
      assert [{:assistant, "broadcast"}] = sync(pid).transcript
    end
  end
end
