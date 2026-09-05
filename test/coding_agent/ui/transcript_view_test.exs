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

  describe "visible/4" do
    defp entries(n), do: Enum.map(1..n, &{:info, "line #{&1}"})

    test "empty" do
      assert TranscriptView.visible([], 5, 0, false) == []
    end

    test "fewer entries than the pane: all visible" do
      assert TranscriptView.visible(entries(3), 10, 0, false) == entries(3)
    end

    test "more entries than the pane: tail follows (auto-scroll)" do
      vis = TranscriptView.visible(entries(50), 3, 0, false)
      # the LAST entries that fit the budget
      assert vis == [{:info, "line 48"}, {:info, "line 49"}, {:info, "line 50"}]
    end

    test "offset pins the window above the bottom" do
      vis = TranscriptView.visible(entries(50), 3, 10, false)
      # offset EXTENDS the budget upward: the tail (newest) stays in
      # view, older entries revealed above it — height + offset worth
      assert length(vis) == 13
      assert List.last(vis) == {:info, "line 50"}
      assert hd(vis) == {:info, "line 38"}
    end

    test "offset clamps at the top" do
      vis = TranscriptView.visible(entries(5), 2, 999, false)
      assert Enum.count(vis) >= 1
      assert hd(vis) == {:info, "line 1"}
    end
  end

  describe "bound_letters + toggle (5c wiring)" do
    test "toggle_tool_output is a keymap binding" do
      km = CodingAgent.UI.Keymap.defaults()
      assert CodingAgent.UI.Keymap.resolve(km, %{key: :t, mod: :none}) == :toggle_tool_output
    end
  end
end
