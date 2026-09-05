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
      assert TranscriptView.height(tool("t1", "shell", "a\nb\nc"), 80, true) == 6
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
      # measured heights drive the viewport: the markdown entry is
      # measured (not estimated — markdown paragraph spacing changes
      # rendered line counts), so derive the expectation from the same
      # measurement
      big = {:assistant, "x\n\nx\n\nx\n\nx\n\nx\n\nx\n\nx\n\nx"}
      entries = [{:info, "a"}, big, {:info, "b"}]

      big_h = TranscriptView.height(big, 80, false)
      total = 1 + big_h + 1

      # scroll far enough that the top clamps at 0 and the big entry
      # crosses the bottom edge
      {top, selected} = TranscriptView.viewport(entries, 4, 8, 80, false)
      assert top == max(total - 4 - 8, 0)

      # the big entry crosses the bottom edge and is the only selected
      names = Enum.map(selected, fn {e, _cursor, _h} -> elem(e, 0) end)
      assert :assistant in names
      assert List.last(selected) |> elem(0) == big
    end
  end

  describe "bound_letters + toggle (5c wiring)" do
    test "toggle_tool_output is a keymap binding" do
      km = CodingAgent.UI.Keymap.defaults()
      assert CodingAgent.UI.Keymap.resolve(km, %{key: :t, mod: :none}) == :toggle_tool_output
    end
  end
end
