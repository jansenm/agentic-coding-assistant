defmodule CodingAgent.UI.TranscriptView do
  @moduledoc """
  Pure transcript layout for the block-based TUI (5c):

  - height measurement per entry — **by rendering**, not by estimating
  - tail-window selection: auto-follow (offset 0) or pinned N lines up,
    clamped — the scroll model from 5a, lifted from lines to blocks.

  Pure and unit-tested; UI.Tui renders the returned window.

  ## Inline labels, not frames

  A `Block` border paints its title ON the border row it occupies
  (verified against the drawn buffer, 2026-10-11), so a single `:bottom`
  rule with a `:bottom`, right-aligned title IS an HTML `<hr>` with a
  label at its end — for free, with the dep's own clipping. That is what
  the transcript uses: a user message and the answer before it are
  separated by one plain rule carrying the message's signature
  (`you → build`, `build`). What marks a block as *what* it is stays the
  role colour (`:text` stated white vs `:reasoning` grey italic), the
  label, and the indent — never an outline.

  A full outline on a scrolling entry has to be re-anchored as it moves
  (its top edge would repaint forever while the content scrolls out from
  under it), and that arithmetic is what broke. A one-sided rule has no
  side columns and nothing to re-anchor: when it scrolls out, it is
  simply gone.

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
  4. the widget text is built at RENDER time ("▸ name\\n", borders,
     hard-break markers in reasoning) — estimating from the entry text
     alone measures a different string than the one painted.

  So `height/3` now renders each widget into an oversized headless
  buffer (the same NIF call the real frame uses, same widget struct
  the renderer draws) and counts painted rows. The widget is built by
  the same code Tui renders with — measurement and paint cannot
  diverge by construction. Results are cached in an ETS table keyed by
  (phash2 of the full widget-defining tuple, width): per-frame cost is
  a lookup, and the streaming text (whose phash changes every frame)
  pays one probe per frame — bounded by the pane width, microseconds.
  """

  alias CodingAgent.UI.Styles
  alias ExRatatui.Text

  # ONE blank row after every block — the user message included. It was 3
  # after every non-user block, with the user's 0 as an exception: that
  # exception existed to make the BOXED user message stand out by
  # contrast. The frames are gone, so the exception lost its reason and
  # the gap is one number again.
  @air 1

  # The separator rows a ruled block carries: one `:bottom` rule. Counted
  # arithmetically because a border paints on its RECT's last row, not on
  # the row after the content — probing it in an oversized rect measures
  # the rect (verified: +401).
  @rule 1

  @typedoc "A transcript entry (shape mirrors UI.Tui state)."
  @type entry ::
          {:user, String.t(), String.t() | nil}
          | {:assistant, String.t(), String.t() | nil}
          | {:reasoning, String.t()}
          | {:tool, String.t(), String.t(), String.t()}
          | {:info, String.t()}
          | {:info, String.t(), String.t() | nil}
  @spec height(entry(), pos_integer(), open_id()) :: pos_integer()
  def height(entry, width, open_id) do
    case normalize(entry) do
      # The ruled blocks. The RULE row is added, not probed: a `:bottom`
      # border paints on its rect's last row, so a probe with an
      # oversized rect would measure the probe, not the message
      # (measured: +401). It is exactly one row, always, and with no
      # padding a one-sided rule leaves the content at the full width —
      # so the bare content is what gets probed.
      {:user, text, _agent} ->
        painted_height(%ExRatatui.Widgets.Paragraph{text: text}, width) + @rule + @air

      {:assistant, text, _agent} ->
        content = painted_height(%ExRatatui.Widgets.Markdown{content: text, wrap: true}, width)
        content + @rule + @air

      # The boxless widgets (reasoning, info, collapsed/expanded tools):
      # probe the exact drawn widget; per-widget chrome already in it.
      normalized ->
        {widget, chrome} = widget_for(normalized, width, open_id)
        painted_height(widget, width) + chrome + @air
    end
  end

  # Entries arrive as 2-tuples ({:user, text}, {:assistant, text},
  # {:info, text}) from the TUI before attribution is resolved, and as
  # 3-tuples carrying the agent name. Normalizing at the single entry
  # boundary lets height/viewport render both forms (callers need not
  # special-case), while the agent-bearing shape carries the footer.
  # Reasoning and tool entries are untouched — they never carry a footer.
  defp normalize({:user, text, agent}), do: {:user, text, agent}
  defp normalize({:user, text}), do: {:user, text, nil}
  defp normalize({:assistant, text, agent}), do: {:assistant, text, agent}
  defp normalize({:assistant, text}), do: {:assistant, text, nil}
  defp normalize({:info, text, agent}), do: {:info, text, agent}
  defp normalize({:info, text}), do: {:info, text, nil}
  defp normalize(other), do: other

  # The widget Tui renders for this entry + extra chrome rows the
  # layout must count beyond painted content (borders around the open
  # tool box). Building the widget HERE is the contract: whatever this
  # returns is what the next frame paints.
  # Same Markdown widget Tui paints for thinking (measure = paint): the
  # style distinguishes it from the answer, not a text prefix.
  defp widget_for({:reasoning, text}, _width, _open_id) do
    {%ExRatatui.Widgets.Markdown{
       content: text,
       style: Styles.role(:reasoning),
       wrap: true
     }, 0}
  end

  defp widget_for({:info, text, _agent}, _width, _open_id) do
    {%ExRatatui.Widgets.Paragraph{text: "  " <> text}, 0}
  end

  defp widget_for({:tool, id, name, content}, _width, open_id) do
    if id == open_id do
      # open: a header row plus the output, indented. No block — the
      # header is the frame's whole job and the indent carries the rest.
      {%ExRatatui.Widgets.Paragraph{
         text: "▾ #{name}\n" <> indent(content),
         style: Styles.role(:muted)
       }, 0}
    else
      # collapsed: Tui paints a bare one-line header (no block)
      {%ExRatatui.Widgets.Paragraph{
         text: tool_header(name, content),
         style: Styles.role(:muted)
       }, 0}
    end
  end

  # two cells of indent: what the frame's side columns used to say
  # ("this is the tool's output"), stated once instead of per row. Public:
  # the painter in Tui builds the same string the probe measures
  # (measure = paint) — one definition of the indent.
  @doc "Indent every line of a tool's output by two cells."
  @spec indent(String.t()) :: String.t()
  def indent(content), do: "  " <> String.replace(content, "\n", "\n  ")

  # The footer for an agent-carrying entry: `agent` is the name or nil
  # (no agent). Shared by the assistant box (this module's footers) and
  # the TUI's rendering — ONE definition of the footer strings, now as
  # role-styled lines (Styles owns the colors; the text keeps its shape).
  @doc "Footer for a user message: names the agent it was handed to."
  @spec user_footer(String.t() | nil) :: ExRatatui.Text.Line.t()
  def user_footer(nil), do: Text.Line.new([Text.Span.new("you", style: Styles.role(:user))])

  def user_footer(agent) do
    Text.Line.new([
      Text.Span.new("you", style: Styles.role(:user)),
      Text.Span.new(" → ", style: Styles.role(:muted)),
      Text.Span.new(agent, style: Styles.role(:agent))
    ])
  end

  @doc "Footer for an assistant reply: the name of the agent that answered."
  @spec agent_footer(String.t() | nil) :: ExRatatui.Text.Line.t()
  def agent_footer(nil), do: Text.Line.new([Text.Span.new("agent", style: Styles.role(:muted))])

  def agent_footer(agent),
    do: Text.Line.new([Text.Span.new(agent, style: Styles.role(:agent))])

  @doc "Rows of air after a block (the TUI clips rects to content and leaves these blank)."
  def air, do: @air

  @doc """
  Total height of the transcript at the given width, measured EAGERLY —
  every entry is probed, the whole session on every call. This is the
  algorithm ADR 028 replaced: nothing on a production path calls it any
  more (the render, the clamp, the hit-test and the scroll diagnostics
  all read `viewport/5`'s lazy tail-first walk). It is kept as the TEST
  primitive — the differential anchor that the lazy walk's entries,
  positions and clamping are checked against — and as the benchmark
  baseline for the eager-vs-lazy comparison. Callers outside a test need
  a reason to accept its cost: 8–12 s cold on a long session.
  """
  @spec total_height([entry()], pos_integer(), open_id()) :: non_neg_integer()
  def total_height(entries, width, open_id) do
    Enum.reduce(entries, 0, &(&2 + height(&1, width, open_id)))
  end

  @doc """
  Viewport model (classic scroll): `offset` counts lines ABOVE the
  bottom edge (0 = follow the tail). Returns `{clamped_offset,
  visible_entries}` where each entry carries its PANE-RELATIVE top row
  (0 = the pane's first row; negative when the entry starts above the
  pane and is rendered clipped).

  **Measurement is lazy and tail-first (ADR 028).** Only the entries
  needed to cover `offset + height` lines from the tail are measured;
  everything above is left untouched until it is scrolled into view. The
  old eager form measured the whole transcript every call — 8–10 s cold
  on a long session — to produce the same pixels.

  The clamp is derived from the same walk: when it reaches the start of
  the list, the accumulated lines ARE the total, so `offset` is clamped
  to `max(total - height, 0)`. While entries remain above the window no
  maximum is known — or needed, because the offset is in range.
  """
  @typep open_id() :: nil | binary()

  @spec viewport([entry()], pos_integer(), non_neg_integer(), pos_integer(), open_id()) ::
          {non_neg_integer(), [{entry(), integer(), pos_integer()}]}
  def viewport([], _height, _offset, _width, _open_id), do: {0, []}

  def viewport(entries, height, offset, width, open_id) do
    # The window in bottom-relative coordinates: [offset, offset + height).
    {measured, total_or_covered, exhausted?} =
      measure_from_tail(entries, width, open_id, offset + height)

    clamped =
      if exhausted? do
        min(offset, max(total_or_covered - height, 0))
      else
        offset
      end

    # The pane's TOP edge counted from the transcript bottom. Normally
    # the pane is a window of `height` above the bottom at `offset`; when
    # the content is SHORTER than the pane it is the content's own top,
    # so short content sits at the pane top instead of floating at the
    # bottom (the old eager form's `max(total - height - offset, 0)` in
    # these coordinates).
    pane_top =
      if exhausted? do
        min(height + clamped, total_or_covered)
      else
        height + clamped
      end

    # `measured` is in list order (head .. tail); each entry carries its
    # BOTTOM edge counted from the transcript bottom (`acc`). An entry is
    # visible when [acc, acc + h) intersects [pane_top - height, pane_top),
    # and its pane-relative top is pane_top - (acc + h).
    selected =
      measured
      |> Enum.filter(fn {_entry, acc, h} -> acc < pane_top and acc + h > pane_top - height end)
      |> Enum.map(fn {entry, acc, h} -> {entry, pane_top - acc - h, h} end)

    {clamped, selected}
  end

  # Walk backwards from the tail, measuring (through the content-keyed
  # cache) until the window's top line is covered. Returns
  # `{measured_in_list_order, accumulated_lines, exhausted?}` — exhausted
  # means the walk reached the head, so the accumulator is the total.
  defp measure_from_tail(entries, width, open_id, target) do
    entries
    |> Enum.reverse()
    |> measure(0, [], width, open_id, target)
  end

  # Nothing left: exhausted — the accumulator is the transcript total.
  defp measure([], acc, measured, _width, _open_id, _target), do: {measured, acc, true}

  # The window's top is covered; entries beyond this line cannot be
  # visible (they start at or above it). Do not measure them.
  defp measure(_rest, acc, measured, _width, _open_id, target) when acc >= target,
    do: {measured, acc, false}

  defp measure([entry | rest], acc, measured, width, open_id, target) do
    h = height(entry, width, open_id)
    # prepend: the walk goes tail -> head, so `measured` ends in list order
    measure(rest, acc + h, [{entry, acc, h} | measured], width, open_id, target)
  end

  # -- the separator rule ------------------------------------------------------

  @doc """
  The one separator: a plain rule under a message, carrying that
  message's signature at its right end (`you → build`, `build`).

  One `:bottom` border whose `:bottom`-positioned title paints on the
  same row is an `<hr>` with an inline label (verified against the drawn
  buffer). `border_type: :plain` — a dotted or rounded rule reads as a
  box edge, and there is no box. `title_style: nil` lets the footer line
  carry its own per-span role styles (a `Block` title_style would
  override them).

  `nil` gives the rule bare (the height probe builds it that way: the
  label cannot change the row count).
  """
  @spec rule(ExRatatui.Text.Line.t() | nil) :: ExRatatui.Widgets.Block.t()
  def rule(footer) do
    Styles.panel(
      borders: [:bottom],
      border_type: :plain,
      title: footer,
      title_style: nil,
      title_position: :bottom,
      title_alignment: :right
    )
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
