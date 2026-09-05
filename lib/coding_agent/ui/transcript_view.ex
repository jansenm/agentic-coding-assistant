defmodule CodingAgent.UI.TranscriptView do
  @moduledoc """
  Pure transcript layout for the block-based TUI (5c):

  - height estimation per entry (wrap-aware approximation at pane width)
  - tail-window selection: auto-follow (offset 0) or pinned N lines up,
    clamped — the scroll model from 5a, lifted from lines to blocks.

  Pure and unit-tested; UI.Tui renders the returned window.
  """

  @border_allowance 2

  @typedoc "A transcript entry (shape mirrors UI.Tui state)."
  @type entry ::
          {:user, String.t()}
          | {:assistant, String.t()}
          | {:tool, String.t(), String.t(), String.t()}
          | {:info, String.t()}

  @doc "Estimated render height of one entry at the given pane width."
  @spec height(entry(), pos_integer(), boolean()) :: pos_integer()
  def height(entry, width, tools_expanded)

  def height({:info, text}, width, _t) do
    wrapped_lines(text, width)
  end

  def height({:user, text}, width, _t) do
    wrapped_lines(text, width) + @border_allowance
  end

  def height({:assistant, text}, width, _t) do
    max(wrapped_lines(text, width), 1)
  end

  def height({:tool, _id, name, content}, width, false) do
    wrapped_lines(header(name, content), width)
  end

  def height({:tool, _id, _name, content}, width, true) do
    wrapped_lines(content, width) + @border_allowance
  end

  @doc """
  Selects the entries visible in a pane of the given height: the last
  entries that fit (auto-follow at offset 0); offset pins the window N
  estimated lines above the bottom, clamped. The FIRST visible entry
  may be cut by the pane top (partial render is fine).
  """
  @spec visible([entry()], pos_integer(), non_neg_integer(), boolean()) :: [entry()]
  def visible([], _height, _offset, _t), do: []

  def visible(entries, height, offset, tools_expanded) do
    # walk from the tail, accumulating heights until the budget is used
    {taken, _acc} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn entry, {acc, used} ->
        h = height(entry, 80, tools_expanded)

        if used >= height + offset do
          {:halt, {acc, used}}
        else
          {:cont, {[entry | acc], used + h}}
        end
      end)

    taken
  end

  defp wrapped_lines(text, width) do
    text
    |> String.split("\n")
    |> Enum.reduce(0, fn line, acc ->
      acc + max(ceil(String.length(line) / max(width, 1)), 1)
    end)
  end

  defp header(name, content) do
    "▸ #{name}: #{content |> String.split("\n") |> List.first() |> String.slice(0, 80)}"
  end
end
