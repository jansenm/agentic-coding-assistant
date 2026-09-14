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

    # PERSISTED (opencode parity): the thinking block stays in the
    # transcript as a dim entry ahead of the answer
    assert Enum.any?(st.transcript, &match?({:reasoning, "step one, step two"}, &1))
  end

  test "thinking persists capped: a long trace keeps its head lines", %{pid: pid} do
    long = Enum.map_join(1..40, "\n", &"line #{&1}")
    send(pid, {:agent, {:reasoning_deltas, long}})
    send(pid, {:agent, {:llm_message, "Answer."}})
    Process.sleep(100)

    st = :sys.get_state(pid).user_state

    assert {:reasoning, capped} = Enum.find(st.transcript, &match?({:reasoning, _}, &1))
    assert length(String.split(capped, "\n")) == 12
    assert String.contains?(capped, "line 12")
    refute String.contains?(capped, "line 13")
  end

  test "no thinking streamed: no empty persisted block", %{pid: pid} do
    send(pid, {:agent, {:llm_message, "Just the answer."}})
    Process.sleep(100)

    st = :sys.get_state(pid).user_state
    refute Enum.any?(st.transcript, &match?({:reasoning, _}, &1))
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

  test "startup provider check: down -> red status + transcript line; up -> recovery", %{
    pid: pid
  } do
    send(
      pid,
      {:agent, {:provider_status, :down, "could not reach the provider (connection refused)"}}
    )

    Process.sleep(100)

    st = :sys.get_state(pid).user_state
    assert st.status == :error
    assert st.provider_down? == true
    {:info, msg} = Enum.find(st.transcript, &match?({:info, _}, &1))
    assert msg =~ "provider unavailable"
    assert msg =~ "connection refused"

    # recovery flips back to idle (only for probe-caused error state)
    send(pid, {:agent, {:provider_status, :up}})
    Process.sleep(100)
    st = :sys.get_state(pid).user_state
    assert st.status == :idle
    assert st.provider_down? == false
  end

  test "a real turn error (status_changed) is not cleared by a later :up", %{pid: pid} do
    reason = %ReqLLM.Error.API.Stream{reason: "Stream failed: boom"}
    send(pid, {:agent, {:status_changed, :error, reason}})
    Process.sleep(100)
    send(pid, {:agent, {:provider_status, :up}})
    Process.sleep(100)

    # no provider_down? flag set -> the error stays a turn error
    st = :sys.get_state(pid).user_state
    assert st.status == :error
  end

  test "resume: provider check broadcast lands on the effective session id", %{pid: _} do
    # fresh instance whose session id we read, then a broadcast on that id
    {:ok, pid} =
      CodingAgent.UI.Tui.start_link(name: nil, test_mode: {120, 40}, scope_root: File.cwd!())

    sid = :sys.get_state(pid).user_state.session_id

    send(pid, {:agent, {:provider_status, :down, "could not reach the provider"}})
    Process.sleep(100)

    st = :sys.get_state(pid).user_state
    assert st.status == :error
    assert st.provider_down? == true
    assert sid != nil
  end

  defp start_tui do
    start_supervised!(%{
      id: String.to_atom("tui-#{System.unique_integer([:positive])}"),
      start:
        {CodingAgent.UI.Tui, :start_link,
         [[name: nil, test_mode: {100, 30}, scope_root: File.cwd!()]]}
    })
  end

  test "sidebar spans the full window height and the input grows while typing" do
    pid = start_tui()
    # let the resize poll fire once so pane dims are real
    Process.sleep(700)
    rt = :sys.get_state(pid)
    buf = fn -> rt.terminal_ref |> ExRatatui.get_buffer_content() |> String.split("\n") end

    rows = buf.()
    # sidebar starts on the first content row; its border column still
    # drawn at the input row (full-height span — it used to stop above)
    assert rows |> Enum.at(1) |> String.contains?("agent")
    assert rows |> Enum.at(26) |> String.contains?("│")

    # floor: empty input = 4 rows; typing 5 lines grows the box
    ExRatatui.textarea_insert_str(
      rt.user_state.textarea,
      "l1\nl2\nl3\nl4\nl5"
    )

    send(pid, :__resize_poll__)
    Process.sleep(150)
    rows = buf.()
    assert rows |> Enum.any?(fn r -> String.contains?(r, "l5") end)
    # 5 typed lines visible = the box grew past its 4-row floor
    box_rows = Enum.count(rows, &String.contains?(&1, "l"))
    assert box_rows >= 5
  end

  test "approval dialog: cleared background, above status, capped width" do
    pid =
      start_supervised!(%{
        id: String.to_atom("tui-#{System.unique_integer([:positive])}"),
        start:
          {CodingAgent.UI.Tui, :start_link,
           [[name: nil, test_mode: {160, 30}, scope_root: File.cwd!()]]}
      })

    Process.sleep(700)

    send(
      pid,
      {:agent,
       {:status_changed, :interrupted,
        [
          %ReqLLM.ToolCall{
            id: "call_1",
            function: %{name: "shell", arguments: Jason.encode!(%{"command" => "mix test"})}
          }
        ]}}
    )

    Process.sleep(800)
    rt = :sys.get_state(pid)
    rows = ExRatatui.get_buffer_content(rt.terminal_ref) |> String.split("\n")

    # dialog visible, centered: its left edge starts well right of
    # the sidebar column (24) — centered on a 160-wide window
    approval = Enum.find(rows, &String.contains?(&1, "APPROVAL"))
    assert approval != nil
    lead = approval |> String.graphemes() |> Enum.find_index(&(&1 == "╔"))
    assert lead > 25

    # interior blanked: no input-box border chars inside the dialog rows
    dialog_rows =
      rows
      |> Enum.drop_while(fn r -> not String.contains?(r, "APPROVAL") end)
      |> Enum.take(5)

    # the status line must stay visible below the dialog
    assert rows |> Enum.at(28) |> String.contains?("approval needed")

    # y = approve line present
    assert Enum.any?(dialog_rows, &String.contains?(&1, "y = approve"))
  end

  test "reasoning deltas with doubled newlines render without blank lines" do
    pid =
      start_supervised!(%{
        id: String.to_atom("tui-#{System.unique_integer([:positive])}"),
        start:
          {CodingAgent.UI.Tui, :start_link,
           [[name: nil, test_mode: {100, 30}, scope_root: File.cwd!()]]}
      })

    Process.sleep(700)
    send(pid, {:agent, {:reasoning_deltas, "line one\n\nline two\n\nline three\n\n"}})
    Process.sleep(800)
    rt = :sys.get_state(pid)
    rows = ExRatatui.get_buffer_content(rt.terminal_ref) |> String.split("\n")

    # the three lines are CONSECUTIVE (no blank rows between them —
    # GLM's doubled newlines squeezed at accumulation)
    idx =
      rows
      |> Enum.with_index()
      |> Enum.find(fn {r, _} -> String.contains?(r, "line one") end)
      |> elem(1)

    assert rows |> Enum.at(idx + 1) |> String.contains?("line two")
    assert rows |> Enum.at(idx + 2) |> String.contains?("line three")
  end

  test "split newline deltas do not grow the thinking box" do
    pid =
      start_supervised!(%{
        id: String.to_atom("tui-#{System.unique_integer([:positive])}"),
        start:
          {CodingAgent.UI.Tui, :start_link,
           [[name: nil, test_mode: {100, 30}, scope_root: File.cwd!()]]}
      })

    Process.sleep(700)

    # GLM-style split deltas: text, newline, blank line as separate events
    Enum.each(["line one", "\n", "\n", "line two", "\n", "\n", "line three", "\n"], fn d ->
      send(pid, {:agent, {:reasoning_deltas, d}})
    end)

    Process.sleep(1000)
    rt = :sys.get_state(pid)
    st = rt.user_state

    # no doubled newlines; at most ONE trailing newline (line separator
    # for the next delta) — the box must not fill with blank rows
    assert st.reasoning == "line one\nline two\nline three\n"

    rows = ExRatatui.get_buffer_content(rt.terminal_ref) |> String.split("\n")

    idx =
      rows
      |> Enum.with_index()
      |> Enum.find(fn {r, _} -> String.contains?(r, "line one") end)
      |> elem(1)

    assert rows |> Enum.at(idx + 1) |> String.contains?("line two")
    assert rows |> Enum.at(idx + 2) |> String.contains?("line three")
  end

  test "esc while running raises the interrupt flag; esc while idle falls through", %{pid: pid} do
    # not running: esc must NOT touch the flag (it falls through to the
    # textarea — popups handle their own esc earlier in the chain)
    :ok =
      ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{
        code: "escape",
        kind: "press",
        modifiers: []
      })

    Process.sleep(150)

    st = :sys.get_state(pid).user_state
    refute st.status == :interrupting

    # running: esc raises the session's interrupt flag
    send(pid, {:agent, {:status_changed, :running}})
    Process.sleep(50)

    :ok =
      ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{
        code: "escape",
        kind: "press",
        modifiers: []
      })

    Process.sleep(150)

    st2 = :sys.get_state(pid).user_state
    assert st2.status == :interrupting
    assert CodingAgent.Core.Session.interrupted?(st2.session_id)
    # the "interrupting…" info line shows in the transcript
    assert Enum.any?(st2.transcript, fn
             {:info, t} -> String.contains?(t, "interrupting")
             _ -> false
           end)

    # cleanup: the flag is per-turn; clear so no other session sees it
    CodingAgent.Core.Session.clear_interrupt(st2.session_id)
  end
end
