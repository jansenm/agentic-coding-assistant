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

  @doc """
  Rendered height of one entry at the given pane width — MEASURED via
  the headless buffer backend (not estimated).

  The estimate-based heights drifted from real markdown rendering
  (markdown reflows inline markup; the naive per-line ceil overshoots
  by ~25% on real agent messages) — the drift showed up as gaps between
  blocks and "scrolling dead" stretches while traversing the gaps
  (found live with the user's real session).

  Measurements are cached per {fingerprint, width} in ETS — content is
  stable within a turn, so repeats are free.
  """
  @spec height(entry(), pos_integer(), boolean()) :: pos_integer()
  def height(entry, width, tools_expanded) do
    case entry do
      {:info, text} ->
        measure_text(text, width)

      {:user, text} ->
        measure_text(text, width) + @border_allowance

      {:assistant, text} ->
        measure_markdown(text, width)

      {:tool, _id, name, content} ->
        if tools_expanded do
          measure_text("▸ #{name}\n" <> content, width) + @border_allowance
        else
          measure_text(header(name, content), width)
        end
    end
  end

  defp measure_text(text, width) do
    max(wrapped_lines(text, width), 1)
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

  # -- measured heights (markdown) -------------------------------------------

  @measure_cache :transcript_view_heights

  defp measure_markdown(text, width) do
    key = {:md, :erlang.phash2(text), width}

    case cache_get(key) do
      :not_found ->
        h = do_measure_markdown(text, width)
        cache_put(key, h)
        h

      h ->
        h
    end
  end

  defp do_measure_markdown(text, width) do
    # draw the widget into an oversized headless buffer, scan for the
    # last non-blank row: the REAL rendered height (markdown reflows
    # inline markup, so estimates drift — measured is exact)
    widget = %ExRatatui.Widgets.Markdown{
      content: text,
      style: %ExRatatui.Style{fg: :white},
      wrap: true
    }

    probe_height = 400
    term = ExRatatui.init_test_terminal(width, probe_height)

    _ =
      ExRatatui.draw(term, [
        {widget, %ExRatatui.Layout.Rect{x: 0, y: 0, width: width, height: probe_height}}
      ])

    last =
      term
      |> ExRatatui.get_buffer_content()
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(0, fn {line, i} ->
        if String.trim(line) != "", do: i + 1
      end)

    max(last, 1)
  end

  defp cache_get(key) do
    case :ets.lookup(@measure_cache, key) do
      [{^key, h}] -> h
      [] -> :not_found
    end
  rescue
    _ -> :not_found
  end

  defp cache_put(key, value) do
    :ets.insert(@measure_cache, {key, value})
  rescue
    _ ->
      :ets.new(@measure_cache, [:named_table, :public, :set, read_concurrency: true])
      :ets.insert(@measure_cache, {key, value})
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
