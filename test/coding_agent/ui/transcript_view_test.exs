defmodule CodingAgent.UI.TranscriptViewTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.TranscriptView

  defp lines(n), do: Enum.map(1..n, &"line #{&1}")

  test "empty transcript" do
    assert TranscriptView.window([], 5) == []
  end

  test "fewer lines than the pane: all visible (top-anchored by slice)" do
    assert TranscriptView.window(lines(3), 5) == ["line 1", "line 2", "line 3"]
  end

  test "more lines than the pane: tail follows" do
    assert TranscriptView.window(lines(10), 5) == [
             "line 6",
             "line 7",
             "line 8",
             "line 9",
             "line 10"
           ]
  end

  test "offset scrolls back N lines from the bottom" do
    assert TranscriptView.window(lines(10), 5, 3) == [
             "line 3",
             "line 4",
             "line 5",
             "line 6",
             "line 7"
           ]
  end

  test "offset clamps: cannot scroll past the top" do
    assert TranscriptView.window(lines(10), 5, 999) == [
             "line 1",
             "line 2",
             "line 3",
             "line 4",
             "line 5"
           ]
  end

  test "offset 0 always shows the tail (auto-follow)" do
    assert TranscriptView.window(lines(20), 4) == ["line 17", "line 18", "line 19", "line 20"]
  end
end
