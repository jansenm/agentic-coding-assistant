defmodule CodingAgent.UI.DisplayTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Display

  # The three consumers that must agree about a string — measure, paint and
  # persistence — all read from this module, so these tests are about the
  # SHAPE a string reaches them in, not about any widget. Nothing here starts
  # a session or a TUI: `Display` is handed values and returns entries.

  # -- the stream buffer -----------------------------------------------------

  test "a same-kind delta extends the last block, a kind switch opens a new one" do
    stream =
      []
      |> Display.append_stream(:assistant, "Hel")
      |> Display.append_stream(:assistant, "lo")
      |> Display.append_stream(:reasoning, "wait")
      |> Display.append_stream(:assistant, "!")

    assert stream == [
             {:assistant, "Hello"},
             {:reasoning, "wait"},
             {:assistant, "!"}
           ]
  end

  test "reasoning deltas drop the carriage returns a split provider emits" do
    assert Display.append_stream([], :reasoning, "one\r\ntwo\r\n") == [
             {:reasoning, "one\ntwo\n"}
           ]
  end

  test "only the LAST assistant block carries the cursor" do
    entries = Display.streaming_entries([{:assistant, "first"}, {:assistant, "second"}])

    assert entries == [{:assistant, "first"}, {:assistant, "second▌"}]
  end

  test "a reasoning block that renders to nothing is not an entry" do
    assert Display.streaming_entries([{:reasoning, "\n"}, {:assistant, "ok"}]) == [
             {:assistant, "ok▌"}
           ]
  end

  # -- the reasoning shape ---------------------------------------------------

  test "the display shape never ends in a newline (the phantom-row invariant)" do
    refute Display.render_reasoning("a thought\n") |> String.ends_with?("\n")
  end

  test "every non-blank line that has a following line gets a hard break" do
    assert Display.render_reasoning("one\ntwo\n") == "one  \ntwo"
  end

  test "fenced code keeps its own newlines" do
    text = "look:\n```\ncode line\nother line\n```\ndone\n"
    rendered = Display.render_reasoning(text)

    assert rendered =~ "```\ncode line\nother line\n```"
  end

  test "hardening twice is hardening once" do
    once = Display.render_reasoning("one\ntwo\n")
    assert Display.render_reasoning(once) == once
  end

  test "a finished trace is capped, and a blank one is nothing at all" do
    assert Display.persist_reasoning("   \n\n") == nil

    {:reasoning, text} = Display.persist_reasoning(Enum.map_join(1..40, "\n", &"line #{&1}"))

    assert length(String.split(text, "\n")) == 12
    assert text =~ "line 1"
    refute text =~ "line 13"
  end

  # -- the tool cap ----------------------------------------------------------

  test "short tool output is kept as it is" do
    assert Display.cap_lines("a\nb\nc") == "a\nb\nc"
  end

  test "long tool output keeps its head, its tail and says how much went missing" do
    text = Enum.map_join(1..40, "\n", &"row #{&1}")
    capped = Display.cap_lines(text)

    assert capped =~ "row 1\n"
    assert String.ends_with?(capped, "row 40")
    assert capped =~ "20 lines elided"
    refute capped =~ "row 20"
  end

  test "trailing blank lines are trimmed before the cap decides" do
    # 30 real rows plus a wall of blanks: without the trim the tail half of
    # the cap would be nothing but blanks
    text = Enum.map_join(1..30, "\n", &"row #{&1}") <> String.duplicate("\n", 20)

    assert Display.cap_lines(text) == Enum.map_join(1..30, "\n", &"row #{&1}")
  end

  # -- what a finished turn becomes -----------------------------------------

  test "no stream and no final text is no entry" do
    assert Display.persist_stream([], nil) == []
  end

  test "no stream but a final text becomes the answer" do
    assert Display.persist_stream([], "the answer") == [{:assistant, "the answer"}]
  end

  test "reasoning ahead of the answer is persisted in arrival order" do
    stream = [{:reasoning, "thinking"}, {:assistant, "the answer"}]

    assert [{:reasoning, _}, {:assistant, answer}] = Display.persist_stream(stream, nil)
    assert answer == "the answer"
  end

  test "a stream that carried only reasoning still gets the session's answer" do
    assert [{:reasoning, _}, {:assistant, "final"}] =
             Display.persist_stream([{:reasoning, "thinking"}], "final")
  end

  # -- the display list ------------------------------------------------------

  test "each assistant entry carries the agent of its own turn" do
    transcript = [
      {:user, "first"},
      {:assistant, "r1"},
      {:user, "second"},
      {:assistant, "r2"}
    ]

    assert Display.entries(transcript, [], ["build", "explore"], nil) == [
             {:user, "first", "build"},
             {:assistant, "r1", "build"},
             {:user, "second", "explore"},
             {:assistant, "r2", "explore"}
           ]
  end

  test "without a recorded turn agent the live turn names the answer" do
    # a fresh session (or the first frame after a send): the turn_agents seed
    # has not been extended yet, so the footer would otherwise read "agent"
    assert Display.entries([{:assistant, "r1"}], [], [], "build") == [
             {:assistant, "r1", "build"}
           ]
  end

  test "the live stream is attributed to the current turn, after the transcript" do
    entries =
      Display.entries([{:user, "q"}, {:assistant, "a"}], [{:assistant, "b"}], ["build"], nil)

    assert List.last(entries) == {:assistant, "b▌", "build"}
  end

  test "reasoning and tool entries pass through in their display shape" do
    tool = {:tool, "tool-1", "mix", "ok"}

    assert Display.entries([{:reasoning, "done  "}, tool], [], nil, nil) == [
             {:reasoning, "done  "},
             tool
           ]
  end

  test "a child tab's entries are all attributed to the child's agent" do
    child = %{
      agent: "explorer",
      transcript: [{:assistant, "done"}, {:info, "noted"}],
      stream: [{:reasoning, "hm"}]
    }

    assert Display.child_entries(child) == [
             {:assistant, "done", "explorer"},
             {:info, "noted", "explorer"},
             {:reasoning, "hm"}
           ]
  end
end
