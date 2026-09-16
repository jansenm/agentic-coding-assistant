defmodule CodingAgent.UI.TranscriptView do
  @moduledoc """
  Pure transcript layout for the block-based TUI (5c):

  - height measurement per entry — **by rendering**, not by estimating
  - tail-window selection: auto-follow (offset 0) or pinned N lines up,
    clamped — the scroll model from 5a, lifted from lines to blocks.

  Pure and unit-tested; UI.Tui renders the returned window.

  ## Why measured-by-render (the newline-bug lesson)

  The reasoning box once grew one phantom blank row per streamed line
  ("scroll up three screens of blanks"). Three trimming patches
  (c4669c4, 0c11bb1, d95ca8a) chased the symptom through every route
  the raw string could leak into the layout, because the root cause
  was HERE: `height/3` and the renderer disagreed about what one
  string paints. Every disagreement lands the same way — the entry
  reserves rows the widget never paints (or paints rows the entry
  clipped), and the error compounds while a block streams.

  Estimates disagree with the renderer in four verified ways
  (`paragraph` wrap on/off, trailing "\\n", interior blanks):

  1. a trailing "\\n" measures +1 row (split yields a trailing "") and
     paints 0 — the phantom row per streamed line;
  2. a `wrap: false` Paragraph CLIPS long lines, estimates count a
     wrap — overmeasure growing with line length;
  3. `wrap: true` Paragraphs and Markdown reflow inline markup —
     char-count estimates drift either way;
  4. the widget text is built at RENDER time ("· thinking: ",
     "▸ name\\n", borders) — estimating from the entry text alone
     measures a different string than the one painted.

  So `height/3` now renders each widget into an oversized headless
  buffer (the same NIF call the real frame uses, same widget struct
  the renderer draws) and counts painted rows. The widget is built by
  the same code Tui renders with — measurement and paint cannot
  diverge by construction. Results are cached in an ETS table keyed by
  (phash2 of the full widget-defining tuple, width): per-frame cost is
  a lookup, and the streaming text (whose phash changes every frame)
  pays one probe per frame — bounded by the pane width, microseconds.
  """

  # border rows (2) + inner padding rows (2) of the user frame
  @user_frame_allowance 4

  # empty rows after every NON-user block (answers, tools, info,
  # reasoning): the user frame stands out BY contrast — everything
  # around it breathes more than it does
  @air 3

  @typedoc "A transcript entry (shape mirrors UI.Tui state)."
  @type entry ::
          {:user, String.t()}
          | {:assistant, String.t()}
          | {:tool, String.t(), String.t(), String.t()}
          | {:info, String.t()}

  @doc """
  Rendered height of one entry at the given width, given which tool
  block (if any) is open. `open_id` matches a `{:tool, id, _, _}`
  entry; nil means every tool block is collapsed.

  Measured by rendering the EXACT widget Tui draws (see the
  moduledoc); `@air` rows are added by this module, not the widget.
  """
  @spec height(entry(), pos_integer(), open_id()) :: pos_integer()
  def height(entry, width, open_id) do
    case entry do
      # the user frame's Block paints border+padding glyphs across its
      # whole rect, so the probe must cover the CONTENT only —
      # chrome (borders + padding) is added arithmetically
      {:user, text} ->
        inner_width = max(width - 4, 10)

        content =
          painted_height(%ExRatatui.Widgets.Paragraph{text: text}, inner_width)

        # user frames get no @air (the border chrome IS the spacing)
        content + @user_frame_allowance

      _ ->
        {widget, chrome} = widget_for(entry, width, open_id)
        painted_height(widget, width) + chrome + @air
    end
  end

  # The widget Tui renders for this entry + extra chrome rows the
  # layout must count beyond painted content (borders around the open
  # tool box). Building the widget HERE is the contract: whatever this
  # returns is what the next frame paints.
  defp widget_for({:reasoning, text}, _width, _open_id) do
    {%ExRatatui.Widgets.Paragraph{
       text: "· thinking: " <> text,
       style: %ExRatatui.Style{fg: :dark_gray, modifiers: [:italic]}
     }, 0}
  end

  defp widget_for({:info, text}, _width, _open_id) do
    {%ExRatatui.Widgets.Paragraph{text: "  " <> text}, 0}
  end

  # (the user frame is measured specially in height/3 — its Block
  # paints border+padding glyphs across the whole probe rect, so its
  # content is probed bare and the chrome added arithmetically)

  defp widget_for({:assistant, text}, _width, _open_id) do
    {%ExRatatui.Widgets.Markdown{
       content: text,
       style: %ExRatatui.Style{fg: :white},
       wrap: true
     }, 0}
  end

  defp widget_for({:tool, id, name, content}, _width, open_id) do
    if id == open_id do
      # the open tool box paints border glyphs across its whole rect
      # (same as the user frame) — probe the CONTENT and add the
      # border rows arithmetically
      {%ExRatatui.Widgets.Paragraph{
         text: "▾ #{name}\n" <> content,
         style: %ExRatatui.Style{fg: :dark_gray}
       }, 2}
    else
      # collapsed: Tui paints a bare one-line header (no block)
      {%ExRatatui.Widgets.Paragraph{
         text: tool_header(name, content),
         style: %ExRatatui.Style{fg: :dark_gray}
       }, 0}
    end
  end

  @doc "Rows of air after a block (the TUI clips rects to content and leaves these blank)."
  def air, do: @air

  @doc """
  Total estimated height of the transcript at the given width — the
  scrollable extent.
  """
  @spec total_height([entry()], pos_integer(), open_id()) :: non_neg_integer()
  def total_height(entries, width, open_id) do
    Enum.reduce(entries, 0, &(&2 + height(&1, width, open_id)))
  end

  @doc """
  Viewport model (classic scroll): `offset` counts lines ABOVE the
  bottom edge (0 = follow the tail). Returns
  `{top_line, visible_entries}` where `top_line` may be negative
  relative to the pane top (partial entries render clipped). Clamped
  so the viewport never scrolls past the top.
  """
  @typep open_id() :: nil | binary()

  @spec viewport([entry()], pos_integer(), non_neg_integer(), pos_integer(), open_id()) ::
          {non_neg_integer(), [{entry(), non_neg_integer(), pos_integer()}]}
  def viewport([], _height, _offset, _width, _t), do: {0, []}

  def viewport(entries, height, offset, width, open_id) do
    total = total_height(entries, width, open_id)
    # top line of the viewport in transcript coordinates
    top = max(total - height - offset, 0)

    # entries intersecting [top, top + height), with their absolute
    # top line (for pane-relative placement)
    pairs =
      entries
      |> Enum.map_reduce(0, fn entry, cursor ->
        h = height(entry, width, open_id)
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

  # -- measured heights (render-into-buffer probe) ----------------------------

  @measure_cache :transcript_view_heights

  # Draw the widget into an oversized headless buffer and scan for the
  # last non-blank row. This is the definition of "rendered height" —
  # no estimate can drift from it, because it IS the render. Cache:
  # the probe is a headless terminal alloc + one native draw per miss
  # (microseconds), and every consumer (measure, viewport, widget
  # building, scroll clamp) hits the same key every frame.
  defp painted_height(widget, width) do
    key = {:painted, widget_key(widget), width}

    case cache_get(key) do
      :not_found ->
        h = do_painted_height(widget, width)
        cache_put(key, h)
        h

      h ->
        h
    end
  end

  # Cache key: every field that changes the paint, from the widget
  # struct itself (phash2 on the struct — nested maps included).
  defp widget_key(widget), do: :erlang.phash2(widget)

  defp do_painted_height(widget, width) do
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
      ensure_table()
      :ets.insert(@measure_cache, {key, value})
  end

  # Lazy creation is racy under parallel renders: two processes can both
  # find no table and race to :ets.new — the loser raises. Create only
  # when absent and treat "already exists" as success.
  defp ensure_table do
    if :ets.whereis(@measure_cache) == :undefined do
      try do
        :ets.new(@measure_cache, [:named_table, :public, :set, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp tool_header(name, content) do
    "▸ #{name}: #{content |> String.split("\n") |> List.first() |> String.slice(0, 80)}"
  end
end
