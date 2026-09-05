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
  Total estimated height of the transcript at the given width — the
  scrollable extent.
  """
  @spec total_height([entry()], pos_integer(), boolean()) :: non_neg_integer()
  def total_height(entries, width, tools_expanded) do
    Enum.reduce(entries, 0, &(&2 + height(&1, width, tools_expanded)))
  end

  @doc """
  Viewport model (classic scroll): `offset` counts lines ABOVE the
  bottom edge (0 = follow the tail). Returns
  `{top_line, visible_entries}` where `top_line` may be negative
  relative to the pane top (partial entries render clipped). Clamped
  so the viewport never scrolls past the top.
  """
  @spec viewport([entry()], pos_integer(), non_neg_integer(), pos_integer(), boolean()) ::
          {non_neg_integer(), [entry()]}
  def viewport([], _height, _offset, _width, _t), do: {0, []}

  def viewport(entries, height, offset, width, tools_expanded) do
    total = total_height(entries, width, tools_expanded)
    # top line of the viewport in transcript coordinates
    top = max(total - height - offset, 0)

    # entries intersecting [top, top + height), with their absolute
    # top line (for pane-relative placement)
    pairs =
      entries
      |> Enum.map_reduce(0, fn entry, cursor ->
        h = height(entry, width, tools_expanded)
        {{entry, cursor, h}, cursor + h}
      end)
      |> elem(0)

    selected =
      pairs
      |> Enum.filter(fn {_entry, cursor, h} ->
        cursor + h > top and cursor < top + height
      end)

    {top, selected}
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
