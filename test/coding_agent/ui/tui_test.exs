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

    test "streaming deltas accumulate in the stream buffer" do
      pid = start_supervised!({Tui, name: nil, test_mode: {80, 10}})

      send(pid, {:agent, {:llm_deltas, "Hel"}})
      send(pid, {:agent, {:llm_deltas, "lo"}})
      send(pid, {:agent, {:status_changed, :running}})

      state = sync(pid)
      assert state.stream == [{:assistant, "Hello"}]
      assert state.status == :running
    end

    test "llm_message moves deltas into the transcript" do
      pid = start_supervised!({Tui, name: nil, test_mode: {80, 10}})

      send(pid, {:agent, {:llm_deltas, "answer text"}})
      send(pid, {:agent, {:llm_message, "answer text"}})
      send(pid, {:agent, {:tool_executed, "shell", "exit 0\n--- output ---\nstuff"}})

      state = sync(pid)
      assert state.stream == []

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

    test "a test-mode TUI starts its session in test_mode too" do
      # The TUI's `test_mode` option IS its test flag (`test_session?/1`),
      # but it used to stop at the view: the session Core started was a
      # live one. The suite noticed as noise (the uncataloged-model
      # warning fired in every ui test once the catalog was warm), but the
      # real stake is the guard: a test-mode session is structurally
      # provider-free. Pin the propagation.
      {:ok, pid} = Tui.start_link(name: nil, test_mode: {80, 10}, scope_root: File.cwd!())

      sid = sync(pid).session_id
      assert {:ok, state} = CodingAgent.Core.Session.state(sid)
      assert state.test_mode
    end

    test "broadcast events reach the TUI and update state" do
      {:ok, pid} = Tui.start_link(name: nil, test_mode: {80, 10}, scope_root: File.cwd!())

      sid = sync(pid).session_id

      Registry.dispatch(CodingAgent.EventRegistry, {:session_events, sid}, fn entries ->
        for {p, _} <- entries, do: send(p, {:agent, sid, {:llm_message, "broadcast"}})
      end)

      # the dispatch sent from THIS process, so the sync call is fenced
      # behind it (per-sender FIFO) — no polling needed
      assert [{:assistant, "broadcast"}] = sync(pid).transcript
    end
  end
end
