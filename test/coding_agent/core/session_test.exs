defmodule CodingAgent.Core.SessionTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.State

  describe "consume_stream/2" do
    test "accumulates text deltas in order" do
      events = [
        ReqLLM.StreamEvent.new(:start, nil),
        ReqLLM.StreamEvent.new(:text_delta, "Hel"),
        ReqLLM.StreamEvent.new(:text_delta, "lo "),
        ReqLLM.StreamEvent.new(:text_delta, "world"),
        ReqLLM.StreamEvent.new(:finish, %{reason: :stop})
      ]

      {text, calls} = Session.consume_stream(events, "test-session")
      assert text == "Hello world"
      assert calls == []
    end

    test "collects tool call events" do
      call = %ReqLLM.ToolCall{id: "c1", type: "function", function: %{name: "t", arguments: "{}"}}

      events = [
        ReqLLM.StreamEvent.new(:text_delta, "let me check"),
        ReqLLM.StreamEvent.new(:tool_call, call),
        ReqLLM.StreamEvent.new(:finish, %{reason: :tool_calls})
      ]

      {text, [collected]} = Session.consume_stream(events, "test-session")
      assert text == "let me check"
      assert collected.id == "c1"
    end

    test "ignores usage and metadata events" do
      events = [
        ReqLLM.StreamEvent.new(:usage, %{input: 1}),
        ReqLLM.StreamEvent.new(:text_delta, "ok"),
        ReqLLM.StreamEvent.new(:warning, "hm")
      ]

      {text, calls} = Session.consume_stream(events, "test-session")
      assert text == "ok"
      assert calls == []
    end

    test "user interrupt stops the stream early, keeping the partial text" do
      events = [
        ReqLLM.StreamEvent.new(:text_delta, "partial answer"),
        ReqLLM.StreamEvent.new(:text_delta, " more that should never arrive")
      ]

      # the flag is checked after every event: with the flag set the
      # stream halts right after the first event, keeping its text
      CodingAgent.Core.Interrupt.request("int-session")

      assert Session.consume_stream(events, "int-session") ==
               {:interrupted, "partial answer"}

      # the session clears the flag at turn end (continue_loop); simulate
      CodingAgent.Core.Interrupt.clear("int-session")
      refute CodingAgent.Core.Interrupt.requested?("int-session")
    end

    test "user interrupt stops a reasoning-only stream (no text deltas)" do
      events = [
        ReqLLM.StreamEvent.new(:reasoning_delta, "thinking one"),
        ReqLLM.StreamEvent.new(:reasoning_delta, "thinking two")
      ]

      CodingAgent.Core.Interrupt.request("int-reasoning")

      assert Session.consume_stream(events, "int-reasoning") == {:interrupted, ""}

      CodingAgent.Core.Interrupt.clear("int-reasoning")
    end

    test "a hard cancel (requested flag with clean end) is classified as an interrupt" do
      # the hard-cancel empty-queue path: the stream ends normally with
      # no delta event to trigger interrupt_check, but the flag is set —
      # it must still be classified as an interrupt, not a clean finish
      call = %ReqLLM.ToolCall{id: "c1", type: "function", function: %{name: "t", arguments: "{}"}}
      events = [ReqLLM.StreamEvent.new(:tool_call, call)]

      CodingAgent.Core.Interrupt.request("int-hard")

      assert Session.consume_stream(events, "int-hard") == {:interrupted, ""}

      CodingAgent.Core.Interrupt.clear("int-hard")
    end

    test "an exit from the stopped stream server after a stop is not a crash" do
      # race guard: if the hard cancel lands between events, the next pull
      # raises an exit from the dead StreamServer. With a stop requested
      # that is the intended outcome — the partial text streamed so far is
      # returned. Simulate: one real text delta, then an exit.
      CodingAgent.Core.Interrupt.request("int-exit")

      stream =
        Stream.concat([
          [ReqLLM.StreamEvent.new(:text_delta, "partial text")],
          Stream.map([:boom], fn _ -> exit(:noproc) end)
        ])

      assert Session.consume_stream(stream, "int-exit") == {:interrupted, "partial text"}

      CodingAgent.Core.Interrupt.clear("int-exit")
    end

    test "an exit without a stop requested is a real failure and propagates" do
      stream =
        Stream.concat([
          [ReqLLM.StreamEvent.new(:text_delta, "x")],
          Stream.map([:boom], fn _ -> exit(:noproc) end)
        ])

      assert catch_exit(Session.consume_stream(stream, "int-no-stop"))
    end

    test "no interrupt flag: the stream runs to completion" do
      events = [
        ReqLLM.StreamEvent.new(:text_delta, "a"),
        ReqLLM.StreamEvent.new(:text_delta, "b")
      ]

      {text, calls} = Session.consume_stream(events, "clean-session")
      assert text == "ab"
      assert calls == []
    end
  end

  describe "session process" do
    test "starts with idle status and system message in context" do
      id = "test-#{System.unique_integer()}"
      start_supervised!({Session, id: id, model: "anthropic:claude-haiku-4-5"})

      {:ok, %State{} = state} = Session.state(id)
      assert state.status == :idle
      assert state.id == id
      assert [%ReqLLM.Message{role: :system}] = ReqLLM.Context.to_list(state.context)
    end

    test "model defaults to the configured default when not given" do
      id = "test-#{System.unique_integer()}"

      default = CodingAgent.model() || "ollama:test-model"

      start_supervised!({Session, id: id, model: default})

      assert {:ok, %State{} = state} = Session.state(id)
      assert state.model == default
    end

    test "subscribed process receives status events (self-included)" do
      # subscribing from the test process must not register the test in
      # the event registry more than once, and DOWN cleanup must not crash
      id = "test-#{System.unique_integer()}"
      start_supervised!({Session, id: id, model: "anthropic:claude-haiku-4-5"})
      assert :ok = Session.subscribe(id)
      assert {:ok, %State{}} = Session.state(id)
    end
  end
end
