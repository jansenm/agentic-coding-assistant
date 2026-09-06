defmodule CodingAgent.UI.TuiAccordionTest do
  @moduledoc """
  Single-open tool accordion: click opens one block, clicking another
  closes the first, ctrl-t opens the most recent block. Hit-testing
  maps a screen row to the covering entry.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.UI.Tui

  setup do
    pid = start_supervised!({Tui, [name: nil, test_mode: {80, 24}, scope_root: File.cwd!()]})
    %{pid: pid}
  end

  test "ctrl-t opens the most recent tool block, ctrl-t again closes it", %{pid: pid} do
    send(pid, {:agent, {:tool_executed, "read_file", "one line"}})
    send(pid, {:agent, {:tool_executed, "shell", "out1\nout2"}})
    Process.sleep(100)

    st = :sys.get_state(pid).user_state
    assert st.open_tool_id == nil

    :ok =
      ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{
        code: "t",
        kind: "press",
        modifiers: ["ctrl"]
      })

    Process.sleep(100)
    st = :sys.get_state(pid).user_state
    # most recent = the shell block
    assert st.open_tool_id != nil
    id = st.open_tool_id
    assert st.transcript |> Enum.find(&match?({:tool, ^id, _, _}, &1)) |> elem(2) == "shell"

    :ok =
      ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{
        code: "t",
        kind: "press",
        modifiers: ["ctrl"]
      })

    Process.sleep(100)
    assert :sys.get_state(pid).user_state.open_tool_id == nil
  end

  test "click on a collapsed tool header opens THAT block", %{pid: pid} do
    send(pid, {:agent, {:tool_executed, "read_file", "one line"}})
    Process.sleep(100)

    # entries are placed TOP-anchored in the pane; frame row 0 is the
    # app margin, so the first pane row is frame row 1
    y = 1

    :ok =
      ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Mouse{
        kind: "down",
        button: "left",
        x: 5,
        y: y
      })

    Process.sleep(100)
    st = :sys.get_state(pid).user_state
    assert st.open_tool_id != nil
  end

  test "click below the transcript pane (input area) does nothing", %{pid: pid} do
    send(pid, {:agent, {:tool_executed, "read_file", "one line"}})
    Process.sleep(100)

    # 24-row terminal: transcript rows are 0..18; 20 is input area
    :ok =
      ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Mouse{
        kind: "down",
        button: "left",
        x: 5,
        y: 20
      })

    Process.sleep(100)
    assert :sys.get_state(pid).user_state.open_tool_id == nil
  end
end
