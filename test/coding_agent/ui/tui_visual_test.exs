defmodule CodingAgent.UI.TuiVisualTest do
  @moduledoc """
  Visual-comfort behaviors: markdown breathing (blank line after
  headings), tool-output caps, reasoning blocks (distinct dim style),
  status-line colors.
  """
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.Tui
  alias CodingAgent.UI.TranscriptView

  defp start_tui(size \\ {80, 24}, opts \\ []) do
    start_supervised!(%{
      id: String.to_atom("tui-#{System.unique_integer([:positive])}"),
      start: {Tui, :start_link, [[name: nil, test_mode: size, scope_root: File.cwd!()] ++ opts]}
    })
  end

  setup do
    pid = start_tui()
    %{pid: pid}
  end

  test "reasoning deltas render as a transient dim block, cleared on the answer", %{pid: pid} do
    agent(pid, {:reasoning_deltas, "step one, "})
    agent(pid, {:reasoning_deltas, "step two"})

    assert sync(pid).stream == [{:reasoning, "step one, step two"}]

    # it participates in layout: the reasoning entry has a measured height
    assert TranscriptView.height({:reasoning, "step one, step two"}, 78, nil) >= 1

    # the answer replaces the thinking block
    agent(pid, {:llm_message, "The answer."})
    st = sync(pid)
    assert st.stream == []
    assert Enum.any?(st.transcript, &match?({:assistant, "The answer."}, &1))

    # PERSISTED (opencode parity): the thinking block stays in the
    # transcript as a dim entry ahead of the answer
    assert Enum.any?(st.transcript, &match?({:reasoning, "step one, step two"}, &1))
  end

  test "answer text interleaves with thoughts in arrival order", %{pid: pid} do
    # the user's report: a statement made while thinking was pinned in a
    # sticky block above the input and later thinking scrolled past it.
    # A statement must stay BETWEEN the thoughts it was made between.
    agent(pid, {:reasoning_deltas, "first thought"})
    agent(pid, {:llm_deltas, "a statement"})
    agent(pid, {:reasoning_deltas, "second thought"})

    assert sync(pid).stream == [
             {:reasoning, "first thought"},
             {:assistant, "a statement"},
             {:reasoning, "second thought"}
           ]

    # persisted in that same order (opencode parity)
    agent(pid, {:llm_message, "a statement"})
    st = sync(pid)

    assert st.stream == []

    assert Enum.filter(
             st.transcript,
             &match?({kind, _} when kind in [:reasoning, :assistant], &1)
           ) ==
             [
               {:reasoning, "first thought"},
               {:assistant, "a statement"},
               {:reasoning, "second thought"}
             ]
  end

  test "reasoning-only stream falls back to the final answer text", %{pid: pid} do
    # no assistant deltas (non-streamed / provider quirk): the session's
    # authoritative text must still land, after the thinking block
    agent(pid, {:reasoning_deltas, "only thinking here"})
    agent(pid, {:llm_message, "The final answer."})

    kinds = Enum.map(sync(pid).transcript, fn {kind, _} -> kind end)
    assert kinds == [:reasoning, :assistant]
  end

  test "thinking persists capped: a long trace keeps its head lines", %{pid: pid} do
    long = Enum.map_join(1..40, "\n", &"line #{&1}")
    agent(pid, {:reasoning_deltas, long})
    agent(pid, {:llm_message, "Answer."})

    st = sync(pid)

    assert {:reasoning, capped} = Enum.find(st.transcript, &match?({:reasoning, _}, &1))
    assert length(String.split(capped, "\n")) == 12
    assert String.contains?(capped, "line 12")
    refute String.contains?(capped, "line 13")
  end

  test "no thinking streamed: no empty persisted block", %{pid: pid} do
    agent(pid, {:llm_message, "Just the answer."})

    st = sync(pid)
    refute Enum.any?(st.transcript, &match?({:reasoning, _}, &1))
  end

  test "assistant box footer shows the turn's agent name, not the neutral label", %{pid: pid} do
    # A fresh session's turn_agents is empty until the local send path
    # records a name; the box footer must still show the agent the session
    # resolved for this turn ({:turn_started, ...}), not fall back to the
    # neutral "agent" label.
    agent(pid, {:turn_started, "build"})
    agent(pid, {:llm_message, "the answer"})

    buffer = Enum.join(buffer(pid), "\n")
    assert buffer =~ "build"
    refute buffer =~ "agent╯"
  end

  test "assistant entries breathe: blank line after headings", %{pid: pid} do
    agent(pid, {:llm_message, "# Title\nbody line"})

    st = sync(pid)
    {:assistant, text} = Enum.find(st.transcript, &match?({:assistant, _}, &1))

    # normalize_entry applied breathe: heading is followed by one blank line
    [first, second | _] = String.split(text, "\n")
    assert first == "# Title"
    assert second == ""
  end

  test "expanded tool output is capped with head+tail and an elision note", %{pid: pid} do
    long = Enum.map_join(1..60, "\n", &"line #{&1}")
    agent(pid, {:tool_executed, "shell", long})

    st = sync(pid)
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
    agent(pid, {:tool_executed, "glob", "lib/coding_agent.ex"})
    agent(pid, {:llm_message, "# Answer\n\nHere is the result of the glob."})

    key(pid, "t", ["ctrl"])

    st = sync(pid)
    {:tool, tool_id, _, _} = Enum.find(st.transcript, &match?({:tool, _, _, _}, &1))
    {:assistant, _} = Enum.find(st.transcript, &match?({:assistant, _}, &1))

    entries = st.transcript
    [tool_h, answer_h] = for e <- entries, do: TranscriptView.height(e, 100, tool_id)

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
    agent(pid, {:tool_executed, "read_file", content})
    agent(pid, {:llm_message, "# Answer\n\nDone."})

    key(pid, "t", ["ctrl"])

    st = sync(pid)
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
    agent(pid, {:tool_executed, "read_file", content})

    st = sync(pid)
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

    agent(pid, {:status_changed, :error, reason})

    st = sync(pid)
    {:info, msg} = Enum.find(st.transcript, &match?({:info, _}, &1))

    assert msg =~ "✖ provider failed"
    # the inspect dump is cut, the human part kept
    assert msg =~ "Stream failed:"
    refute msg =~ "%Finch.TransportError"
    assert st.status == :error
  end

  test "a failed turn flushes partial output instead of dropping it", %{pid: pid} do
    agent(pid, {:reasoning_deltas, "started thinking"})
    agent(pid, {:llm_deltas, "partial answer"})

    reason = %ReqLLM.Error.API.Stream{reason: "Stream failed: boom"}
    agent(pid, {:status_changed, :error, reason})

    st = sync(pid)
    assert st.stream == []

    kinds = Enum.map(st.transcript, fn {kind, _} -> kind end)
    assert kinds == [:reasoning, :assistant, :info]
    assert Enum.any?(st.transcript, &match?({:assistant, "partial answer"}, &1))
  end

  test "startup provider check: down -> red status + transcript line; up -> recovery", %{
    pid: pid
  } do
    agent(
      pid,
      {:provider_status, :down, "could not reach the provider (connection refused)"}
    )

    st = sync(pid)
    assert st.status == :error
    assert st.provider_down? == true
    {:info, msg} = Enum.find(st.transcript, &match?({:info, _}, &1))
    assert msg =~ "provider unavailable"
    assert msg =~ "connection refused"

    # recovery flips back to idle (only for probe-caused error state)
    agent(pid, {:provider_status, :up})
    st = sync(pid)
    assert st.status == :idle
    assert st.provider_down? == false
  end

  test "a real turn error (status_changed) is not cleared by a later :up", %{pid: pid} do
    reason = %ReqLLM.Error.API.Stream{reason: "Stream failed: boom"}
    agent(pid, {:status_changed, :error, reason})
    agent(pid, {:provider_status, :up})

    # no provider_down? flag set -> the error stays a turn error
    st = sync(pid)
    assert st.status == :error
  end

  test "resume: provider check broadcast lands on the effective session id" do
    # fresh instance whose session id we read, then a broadcast on that id
    {:ok, pid} = Tui.start_link(name: nil, test_mode: {120, 40}, scope_root: File.cwd!())

    sid = sync(pid).session_id

    agent(pid, {:provider_status, :down, "could not reach the provider"})

    st = sync(pid)
    assert st.status == :error
    assert st.provider_down? == true
    assert sid != nil
  end

  test "sidebar spans the full window height and the input grows while typing" do
    pid = start_tui({100, 30})
    # seed deterministic pane dims (live resize polling is off in test_mode)
    fire(pid, :__resize_poll__)

    rows = buffer(pid)
    # sidebar starts on the first content row; its border column still
    # drawn at the input row (full-height span — it used to stop above)
    assert rows |> Enum.at(1) |> String.contains?("agent")
    assert rows |> Enum.at(26) |> String.contains?("│")

    # floor: empty input = 4 rows; typing 5 lines grows the box
    ExRatatui.textarea_insert_str(
      sync(pid).textarea,
      "l1\nl2\nl3\nl4\nl5"
    )

    fire(pid, :__resize_poll__)
    rows = buffer(pid)
    assert rows |> Enum.any?(fn r -> String.contains?(r, "l5") end)
    # 5 typed lines visible = the box grew past its 4-row floor
    box_rows = Enum.count(rows, &String.contains?(&1, "l"))
    assert box_rows >= 5
  end

  test "sidebar is wider and toggles off (ctrl-x p / sidebar: false)" do
    pid = start_tui({100, 30})
    fire(pid, :__resize_poll__)

    # visible by default; the panel claims @sidebar_width columns
    assert sync(pid).sidebar_visible?
    assert buffer(pid) |> Enum.at(1) |> String.contains?("agent")

    # the wider panel fits a full model id (the 24-col cut it mid-name:
    # "ollama_cloud:glm-5.3-f|"; 36 leaves room for the whole string)
    st = sync(pid)
    model = st.model || "?"
    assert String.length(model) <= 34

    # toggle off via the menu fast path: the panel is gone, the
    # transcript starts at the left edge
    key(pid, "x", ["ctrl"])
    key(pid, "p")
    refute sync(pid).sidebar_visible?

    rows = buffer(pid)
    refute rows |> Enum.at(1) |> String.contains?("agent")
    # the transcript now begins at column 0 — a reasoning line sits at
    # the left edge with no 36-col gutter before it
    agent(pid, {:reasoning_deltas, "flush left"})
    assert buffer(pid) |> Enum.any?(&String.starts_with?(&1, "  flush left"))

    # toggle back on
    key(pid, "x", ["ctrl"])
    key(pid, "p")
    assert sync(pid).sidebar_visible?
    assert buffer(pid) |> Enum.at(1) |> String.contains?("agent")
  end

  test "sidebar: false seeds the panel off at mount (test seam)" do
    pid = start_tui({100, 30}, sidebar: false)
    refute sync(pid).sidebar_visible?
    refute buffer(pid) |> Enum.at(1) |> String.contains?("agent")
  end

  test "approval dialog: cleared background, above status, capped width" do
    pid = start_tui({160, 30})

    agent(
      pid,
      {:status_changed, :interrupted,
       [
         %ReqLLM.ToolCall{
           id: "call_1",
           function: %{name: "shell", arguments: Jason.encode!(%{"command" => "mix test"})}
         }
       ]}
    )

    rows = buffer(pid)

    # dialog visible, centered on the whole window (it overlays the
    # sidebar, not the transcript pane): its left edge sits in the
    # middle of the 160-wide frame
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

  test "reasoning is markdown: single newlines stay lines, blank runs collapse to one break" do
    # sidebar off: the transcript starts at column 0, so the assertions
    # read the pane directly (no column slicing) — the toggle doubles as
    # the test seam the panel made necessary
    pid = start_tui({100, 30}, sidebar: false)

    # single newlines: markdown would JOIN these as a soft break, so the
    # renderer injects hard breaks — the three lines stay consecutive
    agent(pid, {:reasoning_deltas, "line one\nline two\nline three"})
    rows = buffer(pid)

    idx =
      rows
      |> Enum.with_index()
      |> Enum.find(fn {r, _} -> String.contains?(r, "line one") end)
      |> elem(1)

    assert rows |> Enum.at(idx + 1) |> String.contains?("line two")
    assert rows |> Enum.at(idx + 2) |> String.contains?("line three")

    # a runaway blank run is ONE paragraph break, not a screen of blanks
    # (GLM's split deltas used to grow the box unboundedly under Paragraph)
    pid2 = start_tui({100, 30}, sidebar: false)
    agent(pid2, {:reasoning_deltas, "para one\n\n\n\n\n\npara two"})
    rows2 = buffer(pid2)

    idx2 =
      rows2
      |> Enum.with_index()
      |> Enum.find(fn {r, _} -> String.contains?(r, "para one") end)
      |> elem(1)

    assert rows2 |> Enum.at(idx2 + 1) |> String.trim() == ""
    assert rows2 |> Enum.at(idx2 + 2) |> String.contains?("para two")
  end

  test "reasoning is rendered as markdown structure, not flat text" do
    pid = start_tui({110, 34}, sidebar: false)

    agent(pid, {:reasoning_deltas, "## Plan\ncheck **files** first\n\n```elixir\nx = 1\n```"})

    rows = buffer(pid)

    # inline emphasis is PARSED: the "**" markers are consumed by the
    # widget (a Paragraph would have painted them literally)
    assert Enum.any?(rows, &String.contains?(&1, "check files first"))
    refute Enum.any?(rows, &String.contains?(&1, "**files**"))

    # the heading text and its line survive (the "##" prefix stays in
    # the buffer like the assistant path — the widget styles the span)
    assert Enum.any?(rows, &String.contains?(&1, "Plan"))

    # fenced code survives verbatim: no hard-break spaces injected and
    # the fence markers stay on their own lines
    assert Enum.any?(rows, &String.contains?(&1, "```elixir"))
    assert Enum.any?(rows, &String.contains?(&1, "x = 1"))
    refute Enum.any?(rows, &String.contains?(&1, "x = 1  "))

    # and the lines did NOT melt together (markdown soft break avoided):
    # "check files first" occupies its OWN row, never fused onto the
    # heading row ("## Plan check files first")
    refute Enum.any?(
             rows,
             &(String.contains?(&1, "Plan") and String.contains?(&1, "files first"))
           )
  end

  test "split newline deltas buffer verbatim (markdown paragraph breaks)" do
    pid = start_tui({100, 30}, sidebar: false)

    # GLM-style split deltas: text, newline, blank line as separate events
    Enum.each(["line one", "\n", "\n", "line two", "\n", "\n", "line three", "\n"], fn d ->
      agent(pid, {:reasoning_deltas, d})
    end)

    st = sync(pid)

    # the buffer is verbatim markdown now — blank lines are paragraph
    # breaks, and CommonMark collapses runs of them at render
    assert st.stream == [{:reasoning, "line one\n\nline two\n\nline three\n"}]

    rows = buffer(pid)

    # each paragraph is separated by exactly one blank row
    idx =
      rows
      |> Enum.with_index()
      |> Enum.find(fn {r, _} -> String.contains?(r, "line one") end)
      |> elem(1)

    assert rows |> Enum.at(idx + 1) |> String.trim() == ""
    assert rows |> Enum.at(idx + 2) |> String.contains?("line two")
    assert rows |> Enum.at(idx + 3) |> String.trim() == ""
    assert rows |> Enum.at(idx + 4) |> String.contains?("line three")
  end

  test "esc while running needs TWO presses to raise the interrupt flag", %{pid: pid} do
    # not running: esc must NOT touch the flag (it falls through to the
    # textarea — popups handle their own esc earlier in the chain)
    key(pid, "escape")

    st = sync(pid)
    refute st.status == :interrupting

    # running: a LONE esc only arms (vim muscle memory: esc is pressed
    # out of habit, it must never stop a running turn)
    agent(pid, {:status_changed, :running})

    key(pid, "escape")

    st_armed = sync(pid)
    refute st_armed.status == :interrupting
    assert st_armed.stop_confirm?
    refute CodingAgent.Core.Interrupt.requested?(st_armed.session_id)

    # second esc within the window: stop
    key(pid, "escape")

    st2 = sync(pid)
    assert st2.status == :interrupting
    assert CodingAgent.Core.Interrupt.requested?(st2.session_id)
    refute st2.stop_confirm?
    # the "interrupting…" info line shows in the transcript
    assert Enum.any?(st2.transcript, fn
             {:info, t} -> String.contains?(t, "interrupting")
             _ -> false
           end)

    # cleanup: the flag is per-turn; clear so no other session sees it
    CodingAgent.Core.Interrupt.clear(st2.session_id)
  end

  test "a text key between escs disarms the stop confirm", %{pid: pid} do
    agent(pid, {:status_changed, :running})

    key(pid, "escape")
    assert sync(pid).stop_confirm?

    # the status line tells the user a second esc will stop
    assert Enum.any?(buffer(pid), &String.contains?(&1, "esc again to stop"))

    # typing disarms — the second press must be a real esc pair
    key(pid, "a")
    refute sync(pid).stop_confirm?

    key(pid, "escape")
    st = sync(pid)
    refute st.status == :interrupting
    refute CodingAgent.Core.Interrupt.requested?(st.session_id)
  end

  test "esc while stopping never arms quit; only idle esc does", %{pid: pid} do
    # while busy, esc must never arm the quit confirm — the old cascade
    # (esc -> interrupting -> arm -> quit) killed the app
    agent(pid, {:status_changed, :running})

    key(pid, "escape")
    key(pid, "escape")
    assert sync(pid).status == :interrupting
    refute sync(pid).quit_confirm?

    # the turn is still stopping (no :idle broadcast arrived yet)
    key(pid, "escape")
    st = sync(pid)

    refute st.quit_confirm?
    assert Process.alive?(pid)
    # after the stop, esc re-arms the stop confirm, not quit
    assert st.stop_confirm?

    # and once idle again, esc is allowed to arm quit
    agent(pid, {:status_changed, :idle})
    key(pid, "escape")

    assert sync(pid).quit_confirm?
    refute sync(pid).stop_confirm?

    CodingAgent.Core.Interrupt.clear(st.session_id)
  end

  test "esc to quit requires a double press while idle; a key in between disarms", %{pid: pid} do
    # first esc: arms (does NOT quit)
    key(pid, "escape")

    assert sync(pid).quit_confirm? == true

    # second esc within the window: quits
    key(pid, "escape")

    wait_until(fn -> not Process.alive?(pid) end)

    # fresh TUI: esc then another key disarms the confirm
    pid2 = start_tui({80, 30})

    key(pid2, "escape")
    assert sync(pid2).quit_confirm? == true

    # any other key disarms
    key(pid2, "x")
    assert sync(pid2).quit_confirm? == false

    refute Process.alive?(pid2) == false
  end
end
