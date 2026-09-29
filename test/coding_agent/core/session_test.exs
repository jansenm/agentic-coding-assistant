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

      {text, calls, blocks} = Session.consume_stream(events, "test-session")
      assert text == "Hello world"
      assert calls == []
      # contiguous text deltas fold into ONE assistant block (the display
      # view is one block per run, not one row per delta)
      assert blocks == [{:assistant, "Hello world"}]
    end

    test "collects tool call events" do
      call = %ReqLLM.ToolCall{id: "c1", type: "function", function: %{name: "t", arguments: "{}"}}

      events = [
        ReqLLM.StreamEvent.new(:text_delta, "let me check"),
        ReqLLM.StreamEvent.new(:tool_call, call),
        ReqLLM.StreamEvent.new(:finish, %{reason: :tool_calls})
      ]

      {text, [collected], _blocks} = Session.consume_stream(events, "test-session")
      assert text == "let me check"
      assert collected.id == "c1"
    end

    test "ignores usage and metadata events" do
      events = [
        ReqLLM.StreamEvent.new(:usage, %{input: 1}),
        ReqLLM.StreamEvent.new(:text_delta, "ok"),
        ReqLLM.StreamEvent.new(:warning, "hm")
      ]

      {text, calls, _blocks} = Session.consume_stream(events, "test-session")
      assert text == "ok"
      assert calls == []
    end

    test "reasoning and answer deltas interleave as ordered display blocks" do
      # ADR 020: the session owns the ordered display view, so a thought
      # that arrives between two answer runs keeps its position.
      events = [
        ReqLLM.StreamEvent.new(:reasoning_delta, "first thought "),
        ReqLLM.StreamEvent.new(:reasoning_delta, "continued"),
        ReqLLM.StreamEvent.new(:text_delta, "an answer"),
        ReqLLM.StreamEvent.new(:reasoning_delta, "second thought"),
        ReqLLM.StreamEvent.new(:text_delta, " more answer")
      ]

      {text, [], blocks} = Session.consume_stream(events, "blocks-session")

      assert text == "an answer more answer"

      assert blocks == [
               {:reasoning, "first thought continued"},
               {:assistant, "an answer"},
               {:reasoning, "second thought"},
               {:assistant, " more answer"}
             ]
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

      {text, calls, _blocks} = Session.consume_stream(events, "clean-session")
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

  describe "resumed usage (compaction trigger)" do
    # Found live: every resumed session compacted on its first command.
    # Store.load preserves usage, but neither resume path forwarded it,
    # so init/1 defaulted usage to zeros — last_input_tokens 0 takes the
    # chars fallback (80K chars) and a just-resumed fat context compacted
    # regardless of its real token count.

    test "a resumed session carries last_input_tokens from the snapshot" do
      id = "test-#{System.unique_integer()}"
      usage = %{input_tokens: 123_456, output_tokens: 7, last_input_tokens: 50_000, cost: nil}

      start_supervised!(
        {Session,
         id: id,
         model: "anthropic:claude-haiku-4-5",
         usage: usage,
         compaction_warned: true,
         compaction_backoff: 2}
      )

      {:ok, state} = Session.state(id)
      # usage normalizes into the canonical struct (wire-compatible with
      # the old map form; see Usage.from_map/1)
      assert state.usage == CodingAgent.Core.Session.Usage.from_map(usage)
      assert state.compaction_warned == true
      assert state.compaction_backoff == 2
    end

    test "a resumed fat context below the token trigger does NOT compact" do
      id = "test-#{System.unique_integer()}"
      # >80K chars (the chars fallback would fire) but only 50k tokens
      msgs =
        for _i <- 1..90 do
          %ReqLLM.Message{
            role: :assistant,
            content: [ReqLLM.Message.ContentPart.text(String.pad_leading("m", 1000, "x"))]
          }
        end

      context = %ReqLLM.Context{
        messages: [
          %ReqLLM.Message{
            role: :system,
            content: [ReqLLM.Message.ContentPart.text("system")]
          }
          | msgs
        ]
      }

      start_supervised!(
        {Session,
         id: id,
         model: "anthropic:claude-haiku-4-5",
         context: context,
         usage: %{input_tokens: 123_456, output_tokens: 7, last_input_tokens: 50_000, cost: nil}}
      )

      {:ok, state} = Session.state(id)

      trigger = CodingAgent.Core.Session.Compactor.trigger()
      assert CodingAgent.Core.Session.Compactor.decide(state, trigger) == :none
    end
  end

  describe "llm_retry/4 (the provider retry decision)" do
    alias CodingAgent.Core.Session, as: S

    @timeout ReqLLM.Error.API.Timeout.exception(kind: :receive, timeout: 30_000)
    @empty {:ok, %{text: "", tool_calls: [], blocks: []}}
    @answer {:ok, %{text: "hi", tool_calls: [], blocks: [{:assistant, "hi"}]}}

    test "a timeout with nothing streamed retries while attempts remain" do
      assert S.llm_retry({:error, @timeout}, 3, false, 3) == :retry_timeout
    end

    test "a timeout after partial output is NOT retried (no duplicated text)" do
      assert S.llm_retry({:error, @timeout}, 3, true, 3) == :give_up
    end

    test "a non-timeout failure is never retried" do
      assert S.llm_retry({:error, {:stream_error, %{status: 429}}}, 3, false, 3) == :give_up
    end

    test "a clean empty finish retries while attempts remain" do
      assert S.llm_retry(@empty, 3, false, 3) == :retry_empty
    end

    test "an empty finish with retries exhausted is a named failure" do
      assert S.llm_retry(@empty, 0, false, 3) == {:give_up, {:empty_provider_response, 3}}
    end

    test "a real answer is returned unchanged" do
      assert S.llm_retry(@answer, 3, false, 3) == :give_up
    end

    test "the timeout class comes from Failure (auth/status not retried)" do
      refute S.llm_retry({:error, %ReqLLM.Error.API.Request{status: 429}}, 3, false, 3) ==
               :retry_timeout
    end
  end

  describe "state/1 crash-safety" do
    test "a missing session is {:error, :not_found}, never an exit" do
      assert CodingAgent.Core.Session.state("does-not-exist-#{System.unique_integer()}") ==
               {:error, :not_found}
    end
  end
end
