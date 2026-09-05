defmodule CodingAgent.UI.TranscriptViewTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.TranscriptView

  defp tool(id, name, content), do: {:tool, id, name, content}

  describe "height/3" do
    test "info is its wrapped line count" do
      assert TranscriptView.height({:info, "x"}, 80, false) == 1
    end

    test "user has a border allowance" do
      assert TranscriptView.height({:user, "hello"}, 80, false) == 3
    end

    test "long lines wrap by width" do
      # 200 chars at width 80 -> 3 lines
      assert TranscriptView.height({:assistant, String.duplicate("x", 200)}, 80, false) == 3
    end

    test "collapsed tool is one line" do
      assert TranscriptView.height(tool("t1", "shell", "a\nb\nc"), 80, false) == 1
    end

    test "expanded tool is content + border" do
      assert TranscriptView.height(tool("t1", "shell", "a\nb\nc"), 80, true) == 5
    end
  end

  describe "viewport/5" do
    defp entries(n), do: Enum.map(1..n, &{:info, "line #{&1}"})

    test "empty" do
      assert TranscriptView.viewport([], 5, 0, 80, false) == {0, []}
    end

    test "follow mode: top line pinned so the tail is visible" do
      {top, selected} = TranscriptView.viewport(entries(10), 3, 0, 80, false)
      assert top == 7

      assert selected == [
               {{:info, "line 8"}, 7, 1},
               {{:info, "line 9"}, 8, 1},
               {{:info, "line 10"}, 9, 1}
             ]
    end

    test "offset scrolls up: viewport top decreases" do
      {top, selected} = TranscriptView.viewport(entries(10), 3, 5, 80, false)
      assert top == 2
      assert List.first(selected) |> elem(1) == 2
    end

    test "clamped at the top: cannot scroll above line 0" do
      {top, _} = TranscriptView.viewport(entries(10), 3, 999, 80, false)
      assert top == 0
    end

    test "partial entries at the edges are included" do
      # an 8-line entry crossing the top boundary is selected
      big = {:assistant, String.duplicate("x\n", 7) <> "x"}
      entries = [{:info, "a"}, big, {:info, "b"}]
      {top, selected} = TranscriptView.viewport(entries, 4, 8, 80, false)
      # total = 1 + 8 + 1 = 10; top clamped to 0; the viewport covers
      # transcript lines [0, 4): the "a" entry and the big entry (which
      # crosses the bottom edge — rendered clipped via :scroll). "b"
      # starts at line 9, entirely below the viewport -> excluded.
      assert top == 0
      assert length(selected) == 2
      assert List.first(selected) |> elem(0) == {:info, "a"}
      assert List.last(selected) |> elem(0) == big
      assert List.last(selected) |> elem(2) == 8
    end
  end

  describe "bound_letters + toggle (5c wiring)" do
    test "toggle_tool_output is a keymap binding" do
      km = CodingAgent.UI.Keymap.defaults()
      assert CodingAgent.UI.Keymap.resolve(km, %{key: :t, mod: :none}) == :toggle_tool_output
    end
  end
end
