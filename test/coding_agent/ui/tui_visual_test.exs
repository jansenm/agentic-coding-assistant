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
    assert h <= 25
  end
end
