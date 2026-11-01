defmodule CodingAgent.UI.TuiVisualTest do
  @moduledoc """
  Visual-comfort behaviors: markdown breathing (blank line after
  headings), tool-output caps, reasoning blocks (distinct dim style),
  status-line colors.
  """
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.{Tabs, Tui}
  alias CodingAgent.UI.TranscriptView

  defp start_tui(size \\ {80, 24}, opts \\ []) do
    start_supervised!(%{
      id: String.to_atom("tui-#{System.unique_integer([:positive])}"),
      start: {Tui, :start_link, [[name: nil, test_mode: size, scope_root: File.cwd!()] ++ opts]}
    })
  end

  # The sidebar's first content line: the SCOPE heading (the repo basename).
  # It replaced the " status " Block title (O4): a title on a one-sided
  # border painted as bare text one cell in from the edge, which read as
  # neither a heading nor content. `start_tui/2` scopes every TUI here to
  # the cwd.
  defp sidebar_heading, do: Path.basename(File.cwd!())

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

  test "the assistant's rule carries the turn's agent name, not the neutral label", %{pid: pid} do
    # A fresh session's turn_agents is empty until the local send path
    # records a name; the rule's label must still show the agent the
    # session resolved for this turn ({:turn_started, ...}), not fall back
    # to the neutral "agent" label.
    agent(pid, {:turn_started, "build"})
    agent(pid, {:llm_message, "the answer"})

    rows = buffer(pid)
    buffer = Enum.join(rows, "\n")
    assert buffer =~ "build"
    # no frame: the label rides the rule itself
    refute buffer =~ "╯"
    refute buffer =~ "╰"

    rule_row = Enum.find(rows, &String.contains?(&1, "build"))
    assert rule_row =~ "─"
    assert rule_row =~ "build"
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
    # collapsed by default (header + preview)
    assert Tabs.open_tool_id(st.tabs) == nil

    # the STORED display shape is already capped: 10 head + note + 10 tail
    {:tool, id, "shell", capped} = Enum.find(st.transcript, &match?({:tool, _, _, _}, &1))
    assert String.contains?(capped, "40 lines elided")
    assert String.starts_with?(capped, "line 1\nline 2")
    assert String.ends_with?(capped, "line 59\nline 60")

    h = TranscriptView.height({:tool, id, "shell", capped}, 78, id)
    # capped content (22 lines) + the header row + 1 air
    assert h <= 24
  end

  test "the expanded tool is a header + indented body, and the next entry starts below it",
       %{pid: pid} do
    agent(pid, {:tool_executed, "glob", "lib/coding_agent.ex"})
    agent(pid, {:llm_message, "# Answer\n\nHere is the result of the glob."})

    key(pid, "t", ["ctrl"])

    st = sync(pid)
    {:tool, tool_id, _, _} = Enum.find(st.transcript, &match?({:tool, _, _, _}, &1))
    {:assistant, _} = Enum.find(st.transcript, &match?({:assistant, _}, &1))

    entries = st.transcript
    [tool_h, answer_h] = for e <- entries, do: TranscriptView.height(e, 100, tool_id)

    # no frame: the measured height is the header row, the content rows
    # and the air row — nothing else to reserve
    assert tool_h - TranscriptView.air() >= 2
    # sanity: answer is fully below the tool block
    assert answer_h >= 1

    rows = buffer(pid)
    refute Enum.join(rows, "\n") =~ "tool output"
    # the header is present and the body is indented relative to it
    header = Enum.find_index(rows, &String.contains?(&1, "▾ glob"))
    assert header != nil
    body = Enum.find_index(rows, &String.contains?(&1, "  lib/coding_agent.ex"))
    assert body == header + 1
    assert Enum.at(rows, header) |> String.contains?("▾ glob")
  end

  test "an open tool taller than the pane scrolls its content out; nothing re-anchors", %{
    pid: pid
  } do
    # 40-line tool content + answer: total exceeds the pane, so the tool
    # block's top rows are legitimately above the view. There is no top
    # border to re-anchor any more: the header scrolls away with its
    # content instead of sticking to the pane's first row.
    content = Enum.map_join(1..40, "\n", &"row #{&1}")
    agent(pid, {:tool_executed, "read_file", content})
    agent(pid, {:llm_message, "# Answer\n\nDone."})

    key(pid, "t", ["ctrl"])

    st = sync(pid)
    {:tool, id, _, _} = Enum.find(st.transcript, &match?({:tool, _, _, _}, &1))
    assert Tabs.open_tool_id(st.tabs) == id

    entries = st.transcript
    open_id = Tabs.open_tool_id(st.tabs)
    total = Enum.sum(for e <- entries, do: TranscriptView.height(e, 100, open_id))
    pane_h = CodingAgent.UI.Tui.pane_rect(st).height
    skipped = max(total - pane_h - min(Tabs.scroll_offset(st.tabs), max(total - pane_h, 0)), 0)
    assert skipped >= 1

    rows = buffer(pid)
    # the header is above the view: it must not be glued to the pane top
    refute Enum.any?(rows, &String.contains?(&1, "▾ read_file"))
    # ...and the content that IS in view is the tool's own tail
    assert Enum.any?(rows, &String.contains?(&1, "row 40"))
    # no frame glyph anywhere: nothing to re-anchor
    refute Enum.join(rows, "\n") =~ "╭"
    refute Enum.join(rows, "\n") =~ "╰"
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
    # first poll: paints the frame the assertions below read
    fire(pid, :__resize_poll__)

    rows = buffer(pid)
    # the sidebar's first content row is its scope heading (it was the
    # "status" title until O4 — the heading is a body line now, flush
    # with the panel content instead of floating one cell in from the
    # border). Nothing rules the column off any more: the panel's grey
    # FILL against the transcript's background is the separation, so the
    # full-height claim lives in the cell assertions (tui_cells_test).
    assert rows |> Enum.at(1) |> String.contains?(sidebar_heading())
    refute Enum.any?(rows, &String.contains?(&1, "│"))

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
    assert buffer(pid) |> Enum.at(1) |> String.contains?(sidebar_heading())

    # the model is split into its two halves now (O7): the panel shows
    # "model:" and "provider:" on their own rows, so neither half is
    # clipped (the single 32-char badge cut "…deepseek-v4.1-fl|")
    [provider, id] = (sync(pid).model || ":") |> String.split(":", parts: 2)
    text = Enum.join(buffer(pid), "\n")
    assert text =~ ~r/model:\s+#{Regex.escape(id)}/
    assert text =~ ~r/provider:\s+#{Regex.escape(provider)}/

    # toggle off via the menu fast path: the panel is gone, the
    # transcript starts at the left edge
    key(pid, "x", ["ctrl"])
    key(pid, "p")
    refute sync(pid).sidebar_visible?

    rows = buffer(pid)
    refute rows |> Enum.at(1) |> String.contains?(sidebar_heading())
    refute Enum.join(rows, "\n") =~ "provider:"
    # the transcript now begins at column 0 — a reasoning line sits at
    # the left edge with no 36-col gutter before it
    agent(pid, {:reasoning_deltas, "flush left"})
    assert buffer(pid) |> Enum.any?(&String.starts_with?(&1, "  flush left"))

    # toggle back on
    key(pid, "x", ["ctrl"])
    key(pid, "p")
    assert sync(pid).sidebar_visible?
    assert buffer(pid) |> Enum.at(1) |> String.contains?(sidebar_heading())
  end

  test "sidebar: false seeds the panel off at mount (test seam)" do
    pid = start_tui({100, 30}, sidebar: false)
    refute sync(pid).sidebar_visible?
    rows = buffer(pid)
    refute rows |> Enum.at(1) |> String.contains?(sidebar_heading())
    refute Enum.join(rows, "\n") =~ "provider:"
    # and the panel is out of the layout, not painted empty. (There is no
    # rule glyph left to check — the panel is a filled column now — so
    # this is the symbol-level half; the fill is asserted in
    # tui_cells_test.)
    refute rows |> Enum.at(1) |> String.contains?(sidebar_heading())
  end

  test "the pane geometry the reader measures is the one the painter painted" do
    # measure = paint, from OUTSIDE: `Tui.pane_rect/1` is the pane the
    # hit-test, the clamp and the diagnostics use, and it must be the rect
    # the frame actually paints at — rows above `y` belong to the app
    # margin, rows at `y + height` and below to the band/composer.
    #
    # The two dimensions a stored number could not know are the ones that
    # move: the sidebar (+36 columns) and the composer (the tab strip adds
    # two rows). Asserted over the sizes where the reading measure is
    # actually reached, because the widths differ there too.
    for {w, h} <- [{100, 30}, {160, 30}, {80, 24}], tabs <- [false, true] do
      pid = start_tui({w, h})
      fire(pid, :__resize_poll__)

      if tabs do
        child = %Tabs.Child{agent: "explore", model: "m", transcript: [{:info, "child"}]}

        :sys.replace_state(pid, fn rt ->
          update_in(rt.user_state.tabs.subagents, &Map.put(&1, "c1", child))
        end)
      end

      agent(pid, {:llm_message, "A\nB\nC\nD"})

      pane = Tui.pane_rect(sync(pid))
      assert pane.y >= 1
      assert pane.y + pane.height < h

      rows = buffer(pid)

      # the answer is painted INSIDE the pane rows and nowhere above them
      assert Enum.any?(pane.y..(pane.y + pane.height - 1), fn row ->
               String.contains?(Enum.at(rows, row), "A")
             end)

      refute Enum.any?(0..(pane.y - 1), &String.contains?(Enum.at(rows, &1), "A"))
    end
  end

  test "the pane the readers measure follows the composer, with no resize" do
    # The stale-offset family (N94): the clamp and the diagnostics used to
    # read the pane size from state, which the render path refreshed only
    # on a resize (and, in the old code, on an edit). Anything else that
    # moved the pane between two resizes left the readers measuring an
    # older pane. Now no reader stores a dimension: `pane_rect/1` derives
    # it, so this asserts the derived rect against the painted rows.
    pid = start_tui({100, 30}, sidebar: false)
    fire(pid, :__resize_poll__)

    sid = sync(pid).session_id
    for i <- 1..80, do: agent(pid, sid, {:info, "line #{i}"})

    painted_rows = fn ->
      rows = buffer(pid)
      indexes = for {t, r} <- Enum.with_index(rows), String.contains?(t, "line "), do: r
      {Enum.min(indexes), Enum.max(indexes)}
    end

    # 80 one-row entries (plus the air row each block carries): far taller
    # than the pane, so the transcript fills every painted row. The last
    # entry's air row is blank, which is why the bottom text row is one
    # above the pane's edge.
    pane = Tui.pane_rect(sync(pid))
    assert painted_rows.() == {pane.y, pane.y + pane.height - 2}

    # grow the composer by four rows (five typed lines: the field's floor
    # is two, so 5 lines add three rows and the box's own padding accounts
    # for the rest) — no resize event, no resize poll
    sync(pid).textarea |> ExRatatui.textarea_insert_str("l1\nl2\nl3\nl4\nl5")
    fire(pid, :__resize_poll__)

    st = sync(pid)
    pane = Tui.pane_rect(st)

    assert pane.height == 18 - 4
    # ...and the painted transcript moved with it: the reader and the
    # painter agree on where the pane starts and how tall it is
    assert painted_rows.() == {pane.y, pane.y + pane.height - 2}
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

    # The dialog must not cover the live band (the row above the field) nor
    # the field itself: the pause it asks about IS the band's status. The
    # band's "⏸ approval needed" row and the composer's own meta row (setup:
    # agent · model) both sit BELOW the dialog's bottom border.
    dialog_bottom =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {r, _} -> String.contains?(r, "╚") end)
      |> List.first()
      |> elem(1)

    band_row =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {r, _} -> String.contains?(r, "approval needed") end)
      |> List.first()
      |> elem(1)

    setup_row =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {r, _} -> String.contains?(r, "model ") end)
      |> List.last()
      |> elem(1)

    # band above the field, field above the window's last row, both below
    # the dialog — and the pause rides the band, not the setup row
    assert band_row < setup_row
    assert band_row > dialog_bottom
    assert setup_row > dialog_bottom
    refute rows |> Enum.at(setup_row) |> String.contains?("approval needed")

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
