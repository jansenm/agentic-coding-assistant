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

    test "model defaults to application config when not given" do
      id = "test-#{System.unique_integer()}"
      start_supervised!({Session, id: id})

      assert {:ok, %State{} = state} = Session.state(id)
      assert state.model == CodingAgent.model()
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
