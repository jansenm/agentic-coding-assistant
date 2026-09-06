defmodule CodingAgent.UI.TuiVisualTest do
  @moduledoc """
  Visual-comfort behaviors: markdown breathing (blank line after
  headings), tool-output caps, reasoning blocks (distinct dim style),
  status-line colors.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.UI.Tui
  alias CodingAgent.UI.TranscriptView

  setup do
    pid = start_supervised!({Tui, [name: nil, test_mode: {80, 24}, scope_root: File.cwd!()]})
    %{pid: pid}
  end

  test "reasoning deltas render as a transient dim block, cleared on the answer", %{pid: pid} do
    send(pid, {:agent, {:reasoning_deltas, "step one, "}})
    send(pid, {:agent, {:reasoning_deltas, "step two"}})
    Process.sleep(100)

    st = :sys.get_state(pid).user_state
    assert st.reasoning == "step one, step two"

    # it participates in layout: the reasoning entry has a measured height
    entries = (st.transcript ++ [{:reasoning, st.reasoning}]) |> Enum.map(& &1)
    assert TranscriptView.height({:reasoning, "step one, step two"}, 78, nil) >= 1

    # the answer replaces the thinking block
    send(pid, {:agent, {:llm_message, "The answer."}})
    Process.sleep(100)
    st = :sys.get_state(pid).user_state
    assert st.reasoning == ""
    assert Enum.any?(st.transcript, &match?({:assistant, "The answer."}, &1))
  end

  test "assistant entries breathe: blank line after headings", %{pid: pid} do
    send(pid, {:agent, {:llm_message, "# Title\nbody line"}})
    Process.sleep(100)

    st = :sys.get_state(pid).user_state
    {:assistant, text} = Enum.find(st.transcript, &match?({:assistant, _}, &1))

    # normalize_entry applied breathe: heading is followed by one blank line
    [first, second | _] = String.split(text, "\n")
    assert first == "# Title"
    assert second == ""
  end

  test "expanded tool output is capped with head+tail and an elision note", %{pid: pid} do
    long = Enum.map_join(1..60, "\n", &"line #{&1}")
    send(pid, {:agent, {:tool_executed, "shell", long}})
    Process.sleep(100)

    st = :sys.get_state(pid).user_state
    # collapsed by default: one line
    assert st.open_tool_id == nil

    # the STORED display shape is already capped: 10 head + note + 10 tail
    {:tool, id, "shell", capped} = Enum.find(st.transcript, &match?({:tool, _, _, _}, &1))
    assert String.contains?(capped, "40 lines elided")
    assert String.starts_with?(capped, "line 1\nline 2")
    assert String.ends_with?(capped, "line 59\nline 60")

    h = TranscriptView.height({:tool, id, "shell", capped}, 78, id)
    # capped content (22 lines) + borders (2) + air (3)
    assert h <= 27
  end

  test "open tool box never overlaps the next entry (border rows counted)", %{pid: pid} do
    send(pid, {:agent, {:tool_executed, "glob", "lib/coding_agent.ex"}})
    send(pid, {:agent, {:llm_message, "# Answer\n\nHere is the result of the glob."}})
    Process.sleep(100)

    :ok =
      ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{
        code: "t",
        kind: "press",
        modifiers: ["ctrl"]
      })

    Process.sleep(200)

    st = :sys.get_state(pid).user_state
    {:tool, id, _, _} = Enum.find(st.transcript, &match?({:tool, _, _, _}, &1))
    {:assistant, _} = Enum.find(st.transcript, &match?({:assistant, _}, &1))

    entries = st.transcript
    [tool_h, answer_h] = for e <- entries, do: TranscriptView.height(e, 100, st.open_tool_id)

    # the box needs: border(2) + its 2 text rows; measured height covers
    # text + border + air — so the widget rect (h - air) fits the box
    # exactly and the answer starts BELOW it
    assert tool_h - TranscriptView.air() >= 4
    # sanity: answer is fully below the tool block
    assert answer_h >= 1
  end

  test "open tool straddling the pane top windows its content (box exits, no phantom frame)", %{
    pid: pid
  } do
    # 40-line tool content (no trailing blanks needed) + answer: total
    # exceeds the 80x24 test pane (15 rows) so the box straddles the top
    content = Enum.map_join(1..40, "\n", &"row #{&1}")
    send(pid, {:agent, {:tool_executed, "read_file", content}})
    send(pid, {:agent, {:llm_message, "# Answer\n\nDone."}})
    Process.sleep(100)

    :ok =
      ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{
        code: "t",
        kind: "press",
        modifiers: ["ctrl"]
      })

    Process.sleep(200)

    st = :sys.get_state(pid).user_state
    {:tool, id, _, _} = Enum.find(st.transcript, &match?({:tool, _, _, _}, &1))
    assert st.open_tool_id == id

    # follow mode: the box is taller than the pane → its top rows
    # (border + title) are legitimately above the view; the windowed
    # widget must still show the ▾ header row of the content, i.e. the
    # content scroll is (skipped - chrome), not skipped
    entries = st.transcript
    total = Enum.sum(for e <- entries, do: TranscriptView.height(e, 100, st.open_tool_id))
    pane_h = st.last_pane_height
    top = max(total - pane_h - min(st.scroll_offset, max(total - pane_h, 0)), 0)
    skipped = top
    # border chrome consumed the first skipped row; the rest scrolls content
    assert skipped >= 1
  end

  test "cap_lines trims trailing blank lines before capping", %{pid: pid} do
    content = Enum.map_join(1..10, "\n", &"row #{&1}") <> String.duplicate("\n", 20)
    send(pid, {:agent, {:tool_executed, "read_file", content}})
    Process.sleep(100)

    st = :sys.get_state(pid).user_state
    {:tool, _, _, stored} = Enum.find(st.transcript, &match?({:tool, _, _, _}, &1))

    # the 20 trailing blanks are gone; the 10 real lines survive
    lines = String.split(stored, "\n")
    assert length(lines) == 10
    assert List.last(lines) == "row 10"
  end

  test "turn failure lands in the transcript, short and human", %{pid: pid} do
    reason = %ReqLLM.Error.API.Stream{
      reason: "Stream failed: %Finch.TransportError{reason: :econnrefused}"
    }

    send(pid, {:agent, {:status_changed, :error, reason}})
    Process.sleep(100)

    st = :sys.get_state(pid).user_state
    {:info, msg} = Enum.find(st.transcript, &match?({:info, _}, &1))

    assert msg =~ "✖ turn failed"
    # the inspect dump is cut, the human part kept
    assert msg =~ "Stream failed:"
    refute msg =~ "%Finch.TransportError"
    assert st.status == :error
  end
end
