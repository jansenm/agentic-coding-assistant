# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.Composer do
  @moduledoc """
  The composer panel: the input field plus its meta row, on ONE chrome
  surface.

  This is the single home for the composer's geometry and its look. The
  TUI (`CodingAgent.UI.Tui`) supplies a struct of already-resolved
  values — the textarea handle, the identity names, the transient note —
  and this module measures the panel and places the widgets. Nothing here
  reads config, the session or the clock: the caller resolves the strings
  and passes them in, so *layout* and *state* stay separate concerns.

  ## Geometry (the "gepresst" report)

      +--------------------------------------------+  <- chrome fill, WHOLE rect
      |  [primary]  explore                         |  <- TAB row (only once a child exists)
      |                                             |  <- one blank row of air
      |  <textarea>                                 |  <- 1-cell padding
      |                                             |  <- one blank row of air
      |  build · model …                            |  <- SETUP row: next input
      +--------------------------------------------+

  There is deliberately NO border — a frame around the field read as
  "c64". The block that paints is a pure FILL: it carries the surface's
  background over the whole rect, one cell WIDER than the fields inside
  it, and the fields (tab row, textarea, meta) sit inside the padding.
  That is the "the background goes on past the fields" shape: the
  surface reads as one panel, the text as something standing in it.

  The TAB row is part of this panel, not a region of its own: everything
  in the bottom box answers "how do I plan the next move" (which view,
  which agent, which model), so it is one information unit with one
  padding. It used to be a separate layout row flush with the pane edge,
  which is why it alone had no padding.

  The meta row is REAL content on its own row, not a `Block` title on
  the field: a title paints over the last row of its rect (F6), which is
  the collision this layout removes. It renders as a borderless block
  title pair (left identity, right slot) on a dedicated, otherwise
  empty row, so both halves share one line without fighting the text.

  The right half of that row is the composer's OUTERMOST row, so it is
  where transient text lives: the caller's `note` (an esc confirm, the
  menu prompt, a one-off "model → …" report, or — behind a debug flag —
  the scroll diagnostics). With neither, the right half is EMPTY — the
  status is not this row's job (see below).

  ## This row is SETUP; the status is the live band above
  ## (owner decision, 2026-09-23)

  The meta row answers "what will handle the NEXT input": the agent and
  model that Tab and the model menu change. What the RUNNING turn is
  doing is a different question — the two can differ, because a switch
  applies at the turn boundary — so it lives in its own row above the
  field (`UI.LiveBand`), which ALWAYS paints the status, running or not.
  Two places answering the same question is how a UI starts lying, so
  this module is handed no status at all: the note and the diagnostics
  are the only transient text here.
  """
  alias CodingAgent.UI.Styles
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text
  alias ExRatatui.Widgets.{Block, Paragraph, Textarea}

  # the field's line floor / cap (the composer grows while typing,
  # opencode-style, but never shrinks below the floor: an empty field
  # keeps two text rows of breathing room)
  @lines 2
  @max_lines 10

  # one cell of inset on all four sides — the text and the meta row must
  # not touch the surface's edge
  @padding 1
  # one blank row between the typed text and the meta row
  @gap 1

  # one blank row between the tab row and the field
  @tab_gap 1

  @type t :: %__MODULE__{
          textarea: reference() | nil,
          placeholder: String.t(),
          agent: String.t() | nil,
          model: String.t() | nil,
          note: String.t() | nil,
          diagnostics: String.t() | nil,
          tab_line: ExRatatui.Text.Line.t() | nil,
          max_lines: pos_integer()
        }

  defstruct textarea: nil,
            placeholder: "",
            agent: nil,
            model: nil,
            note: nil,
            diagnostics: nil,
            tab_line: nil,
            max_lines: @max_lines

  # Rows the tab strip adds to the panel when a child tab exists: the row
  # itself plus the blank row under it. ONE definition — the height and
  # the layout split both read it, so they cannot disagree.
  @tab_block 1 + @tab_gap

  # The strip as layout segments (empty when there is no strip).
  defp strip_segments(%__MODULE__{tab_line: nil}), do: []

  defp strip_segments(%__MODULE__{}), do: [{:length, 1}, {:length, @tab_gap}]

  @doc "Builds a composer from resolved values (see the moduledoc)."
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  The panel height (the measure side of the measure/paint contract): the
  typed lines (clamped), the tab strip when one exists, and the padding
  ring; inside it, one blank row under the tab strip and one under the
  field.
  """
  @spec height(t()) :: pos_integer()
  def height(%__MODULE__{} = composer),
    do: height_for(composer.tab_line != nil, composer.textarea, composer.max_lines)

  @doc """
  The panel height from the three facts it actually depends on: whether a
  tab strip exists, how many lines the field holds and the line cap. The
  TUI needs the height BEFORE it can build a composer (the composer's own
  meta row carries the scroll diagnostics, whose pane math needs the
  height), so this is the one definition `height/1` and the layout share.
  """
  @spec height_for(boolean(), reference() | nil, pos_integer()) :: pos_integer()
  def height_for(has_tabs?, textarea, max_lines \\ @max_lines) do
    @padding +
      if(has_tabs?, do: @tab_block, else: 0) +
      text_line_count(textarea, max_lines) +
      @gap +
      1 +
      @padding
  end

  @doc """
  The floor height (an empty composer: two text rows, no tab strip) — the
  state-side math before any render touches it.
  """
  @spec min_height() :: pos_integer()
  def min_height, do: height_for(false, nil)

  @doc """
  Places the composer into `rect` and returns `{widget, rect}` tuples for
  `ExRatatui.draw/2` — fill first (bottom layer), then the strip and the
  fields on top.
  """
  @spec placements(t(), Rect.t()) :: [{ExRatatui.widget(), Rect.t()}]
  def placements(%__MODULE__{} = composer, %Rect{} = rect) do
    inner = inset(rect)
    {tab_area, text_area, meta_area} = split(composer, inner)

    [{fill(), rect}] ++
      tab_widgets(composer, tab_area) ++
      [
        {textarea_widget(composer), text_area},
        {meta_widget(composer), meta_area}
      ]
  end

  defp text_line_count(nil, _max_lines), do: @lines

  defp text_line_count(ta, max_lines),
    do: ta |> ExRatatui.textarea_line_count() |> max(1) |> min(max_lines)

  # the surface: a borderless block whose style fills its whole rect —
  # a widget-level bg would only paint the rows a widget writes (F4)
  defp fill, do: %Paragraph{text: "", block: Styles.panel(borders: [], surface: :chrome)}

  # the tab strip, or nothing at all when no child tab exists. It is a
  # body row on the same padding as the rest of the panel (the fill
  # underneath carries the surface).
  defp tab_widgets(%__MODULE__{tab_line: nil}, _area), do: []

  defp tab_widgets(%__MODULE__{tab_line: line}, area),
    do: [{%Paragraph{text: line, style: Styles.surface(:chrome)}, area}]

  defp inset(rect) do
    %Rect{
      x: rect.x + @padding,
      y: rect.y + @padding,
      width: max(rect.width - 2 * @padding, 4),
      height: max(rect.height - 2 * @padding, 1)
    }
  end

  # The panel, top to bottom: the tab strip (one row + one blank row,
  # only when it exists), the field, one blank row, the meta row. One
  # split, so the strip can never claim a row the height did not count —
  # and, because it is a segment of the SAME inner rect, it inherits the
  # panel's padding instead of being indented per line.
  defp split(composer, inner) do
    case strip_segments(composer) do
      [] ->
        case Layout.split(inner, :vertical, [{:min, 0}, {:length, @gap}, {:length, 1}]) do
          [text_area, _gap, meta] -> {empty_rect(inner), text_area, meta}
          _ -> {empty_rect(inner), inner, inner}
        end

      strip ->
        segments = strip ++ [{:min, 0}, {:length, @gap}, {:length, 1}]

        case Layout.split(inner, :vertical, segments) do
          [tab_area, _strip_gap, text_area, _gap, meta] ->
            {tab_area, text_area, meta}

          _ ->
            {empty_rect(inner), inner, inner}
        end
    end
  end

  defp empty_rect(%Rect{} = rect), do: %Rect{rect | height: 0}

  defp textarea_widget(composer) do
    %Textarea{
      state: composer.textarea,
      placeholder: composer.placeholder,
      placeholder_style: Styles.role(:muted, :chrome),
      line_number_style: nil,
      # the text on the surface: the `:text` role on `:chrome`, so it is
      # the SAME stated white as the transcript (not the terminal's).
      style: Styles.role(:text, :chrome),
      # the cursor is a CELL STYLE, not a hardware cursor; the dep default
      # is an empty style, which overwrites tui-textarea's own reversed
      # default and paints nothing (found live: "you cannot see where you
      # type"). `cursor_line_style` stays empty — a reversed char is
      # enough in a multi-line composer.
      cursor_style: %Style{modifiers: [:reversed]},
      cursor_line_style: %Style{},
      block: nil
    }
  end

  # the meta row: identity left, the slot right, on their own row (a
  # block title pair with no border, over an empty paragraph — the fill
  # comes from the layer below, the per-span roles from the lines
  # themselves)
  defp meta_widget(composer) do
    %Paragraph{
      text: "",
      block: %Block{
        borders: [],
        # nil: the title lines carry their own per-span role styles
        title_style: nil,
        titles: [
          %Block.Title{content: identity(composer), position: :bottom, alignment: :left},
          %Block.Title{content: slot(composer), position: :bottom, alignment: :right}
        ]
      }
    }
  end

  # `agent · model <id>` — the identity of what will handle the next
  # input. No "you" and no arrow (owner decision: the input IS the user's,
  # saying so is noise; the arrow was visual clutter). Every span names
  # the `:chrome` surface (the fill is explicit there, so a role resolved
  # against another surface would be chosen for the wrong background).
  defp identity(composer) do
    prefix =
      if composer.agent do
        [
          Text.Span.new(composer.agent, style: Styles.role(:agent, :chrome)),
          Text.Span.new(" · ", style: Styles.role(:muted, :chrome))
        ]
      else
        []
      end

    (prefix ++
       [
         Text.Span.new("model ", style: Styles.role(:muted, :chrome)),
         # the WHOLE id: a hard cap hid the version that distinguishes one
         # model from another; the surface clips if the pane is too narrow
         Text.Span.new(composer.model || "?", style: Styles.role(:model, :chrome))
       ])
    |> Text.Line.new()
  end

  # The right half of the meta row: the composer's OUTERMOST row, so the
  # one place transient text can live without reflowing anything. The
  # `note` (esc confirm, menu prompt, a report like "model → …") wins
  # over a bare debug `diagnostics` dump; with neither, the half is
  # blank.
  #
  # The status is NOT here — it is the live band's job (`UI.LiveBand`,
  # above the field), and it paints it whether or not a turn runs. A
  # second copy on this row would be the same fact twice, next to a
  # DIFFERENT identity (this row names what the next input will use).
  defp slot(composer) do
    cond do
      is_binary(composer.note) ->
        Text.Line.new([Text.Span.new(composer.note, style: Styles.role(:muted, :chrome))])

      is_binary(composer.diagnostics) ->
        Text.Line.new([
          Text.Span.new(composer.diagnostics, style: Styles.role(:muted, :chrome))
        ])

      true ->
        Text.Line.new([Text.Span.new("", style: Styles.role(:muted, :chrome))])
    end
  end
end
