defmodule CodingAgent.UI.TuiAccordionTest do
  @moduledoc """
  Single-open tool accordion: click opens one block, clicking another
  closes the first, ctrl-t opens the most recent block. Hit-testing
  maps a screen row to the covering entry.
  """
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.Tui

  setup do
    pid = start_supervised!({Tui, [name: nil, test_mode: {80, 24}, scope_root: File.cwd!()]})
    %{pid: pid}
  end

  test "ctrl-t opens the most recent tool block, ctrl-t again closes it", %{pid: pid} do
    send(pid, {:agent, {:tool_executed, "read_file", "one line"}})
    send(pid, {:agent, {:tool_executed, "shell", "out1\nout2"}})

    st = sync(pid)
    assert st.open_tool_id == nil

    key(pid, "t", ["ctrl"])
    st = sync(pid)
    # most recent = the shell block
    assert st.open_tool_id != nil
    id = st.open_tool_id
    assert st.transcript |> Enum.find(&match?({:tool, ^id, _, _}, &1)) |> elem(2) == "shell"

    key(pid, "t", ["ctrl"])
    assert sync(pid).open_tool_id == nil
  end

  test "click on a collapsed tool header opens THAT block", %{pid: pid} do
    send(pid, {:agent, {:tool_executed, "read_file", "one line"}})

    # entries are placed TOP-anchored in the pane; frame row 0 is the
    # app margin, so the first pane row is frame row 1
    y = 1

    click(pid, 5, y)
    assert sync(pid).open_tool_id != nil
  end

  test "click below the transcript pane (input area) does nothing", %{pid: pid} do
    send(pid, {:agent, {:tool_executed, "read_file", "one line"}})

    # 24-row terminal: transcript rows are 0..18; 20 is input area
    click(pid, 5, 20)
    assert sync(pid).open_tool_id == nil
  end

  test "the clickable row IS the painted header row, with the sidebar on and wrapping above", %{
    pid: pid
  } do
    # Regression (measured live): the hit-test measured entries at
    # `terminal - 4` while the renderer paints at `measure | main - 2 -
    # sidebar - 2` — 96 vs 60 at 100x30 with the sidebar on. The wrapped
    # answer above the tool therefore reserved fewer rows than it
    # painted, and the tool's hit band sat ROWS ABOVE its header: the
    # click landed on the line above the one the human aimed at.
    #
    # The terminal here is 80 wide and the sidebar is ON (the default),
    # so the two widths differ by 36 columns.
    long = String.duplicate("word ", 40)
    send(pid, {:agent, {:llm_message, long}})
    send(pid, {:agent, {:tool_executed, "shell", "PROBE"}})

    rows = buffer(pid)
    header_row = Enum.find_index(rows, &String.contains?(&1, "▸ shell"))
    assert header_row != nil

    # clicking the painted header row opens it
    click(pid, 5, header_row)
    assert sync(pid).open_tool_id != nil

    # ...and closing it again through the same row
    click(pid, 5, header_row)
    assert sync(pid).open_tool_id == nil

    # the rows just above the header belong to the answer, not the tool:
    # this is what the width bug broke (the band reached into them)
    for y <- [header_row - 1, header_row - 2], y >= 1 do
      click(pid, 5, y)
      assert sync(pid).open_tool_id == nil, "row #{y} (above the header) opened the tool"
    end
  end
end
