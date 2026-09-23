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
      |  <textarea>                                 |  <- 1-cell padding
      |                                             |  <- one blank row of air
      |  build · model …                            |  <- SETUP row: next input
      +--------------------------------------------+

  There is deliberately NO border — a frame around the field read as
  "c64". The block that paints is a pure FILL: it carries the surface's
  background over the whole rect, one cell WIDER than the fields inside
  it, and the fields (textarea, meta) sit inside the padding. That is
  the "the background goes on past the fields" shape: the surface reads
  as one panel, the text as something standing in it.

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

  @type t :: %__MODULE__{
          textarea: reference() | nil,
          placeholder: String.t(),
          agent: String.t() | nil,
          model: String.t() | nil,
          note: String.t() | nil,
          diagnostics: String.t() | nil,
          max_lines: pos_integer()
        }

  defstruct textarea: nil,
            placeholder: "",
            agent: nil,
            model: nil,
            note: nil,
            diagnostics: nil,
            max_lines: @max_lines

  @doc "Builds a composer from resolved values (see the moduledoc)."
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  The panel height (the measure side of the measure/paint contract): the
  typed lines (clamped), plus one blank row, the meta row and the
  padding ring.
  """
  @spec height(t()) :: pos_integer()
  def height(%__MODULE__{} = composer) do
    @padding + min(text_lines(composer), composer.max_lines) + @gap + 1 + @padding
  end

  @doc """
  The floor height (an empty composer) — the state-side math before any
  render, and without a textarea.
  """
  @spec min_height() :: pos_integer()
  def min_height, do: @padding + @lines + @gap + 1 + @padding

  @doc """
  Places the composer into `rect` and returns `{widget, rect}` tuples for
  `ExRatatui.draw/2` — fill first (bottom layer), then the fields on top.
  """
  @spec placements(t(), Rect.t()) :: [{ExRatatui.widget(), Rect.t()}]
  def placements(%__MODULE__{} = composer, %Rect{} = rect) do
    inner = inset(rect)
    {text_area, meta_area} = split(inner)

    [
      {fill(), rect},
      {textarea_widget(composer), text_area},
      {meta_widget(composer), meta_area}
    ]
  end

  defp text_lines(%{textarea: nil}), do: @lines
  defp text_lines(%{textarea: ta}), do: max(ExRatatui.textarea_line_count(ta), 1)

  # the surface: a borderless block whose style fills its whole rect —
  # a widget-level bg would only paint the rows a widget writes (F4)
  defp fill, do: %Paragraph{text: "", block: Styles.panel(borders: [], surface: :chrome)}

  defp inset(rect) do
    %Rect{
      x: rect.x + @padding,
      y: rect.y + @padding,
      width: max(rect.width - 2 * @padding, 4),
      height: max(rect.height - 2 * @padding, 1)
    }
  end

  # the inner area minus the air row and the meta row is the textarea's
  defp split(inner) do
    case Layout.split(inner, :vertical, [{:min, 0}, {:length, @gap}, {:length, 1}]) do
      [text_area, _gap, meta] -> {text_area, meta}
      _ -> {inner, inner}
    end
  end

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
