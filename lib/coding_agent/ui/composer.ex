defmodule CodingAgent.UI.Composer do
  @moduledoc """
  The composer panel: the input field plus its meta row, on ONE chrome
  surface.

  This is the single home for the composer's geometry and its look. The
  TUI (`CodingAgent.UI.Tui`) supplies a struct of already-resolved
  values — the textarea handle, the identity names, the status — and this
  module measures the panel and places the widgets. Nothing here reads
  config, the session or the clock: the caller resolves the elapsed
  seconds and passes them in, so *layout* and *time* stay separate
  concerns.

  ## Geometry (the "gepresst" report)

      +--------------------------------------------+  <- chrome fill, WHOLE rect
      |  <textarea>                                 |  <- 1-cell padding
      |                                             |  <- one blank row of air
      |  you -> build · model …            ○ idle    |  <- meta row: identity | status
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
  title pair (left identity, right status) on a dedicated, otherwise
  empty row, so both halves share one line without fighting the text.
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
          status: atom(),
          provider_down?: boolean(),
          spin: non_neg_integer() | nil,
          active_tool: String.t() | nil,
          tool_elapsed_s: non_neg_integer() | nil,
          silence_s: non_neg_integer() | nil,
          max_lines: pos_integer()
        }

  defstruct textarea: nil,
            placeholder: "",
            agent: nil,
            model: nil,
            status: :idle,
            provider_down?: false,
            spin: nil,
            active_tool: nil,
            tool_elapsed_s: nil,
            silence_s: nil,
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

  # the meta row: identity left, status right, on their own row (a block
  # title pair with no border, over an empty paragraph — the fill comes
  # from the layer below, the per-span roles from the lines themselves)
  defp meta_widget(composer) do
    %Paragraph{
      text: "",
      block: %Block{
        borders: [],
        # nil: the title lines carry their own per-span role styles
        title_style: nil,
        titles: [
          %Block.Title{content: identity(composer), position: :bottom, alignment: :left},
          %Block.Title{content: status(composer), position: :bottom, alignment: :right}
        ]
      }
    }
  end

  # `you → agent · model <id>` — the identity relationship keeps its
  # arrow shape; every span names the `:chrome` surface (the fill is
  # explicit there, so a role resolved against another surface would be
  # chosen for the wrong background)
  defp identity(composer) do
    [
      Text.Span.new("you", style: Styles.role(:user, :chrome)),
      if(composer.agent,
        do: [
          Text.Span.new(" → ", style: Styles.role(:muted, :chrome)),
          Text.Span.new(composer.agent, style: Styles.role(:agent, :chrome))
        ],
        else: []
      ),
      Text.Span.new(" · ", style: Styles.role(:muted, :chrome)),
      Text.Span.new("model ", style: Styles.role(:muted, :chrome)),
      # the WHOLE id: a hard cap hid the version that distinguishes one
      # model from another; the surface clips if the pane is too narrow
      Text.Span.new(composer.model || "?", style: Styles.role(:model, :chrome))
    ]
    |> List.flatten()
    |> Text.Line.new()
  end

  # the status answers "is the model still working?", asked at the input.
  # The active tool names itself; a busy-but-silent turn shows the silence
  # duration; idle shows the badge so the row is never bare.
  defp status(composer) do
    step = if Styles.busy?(composer.status), do: composer.spin, else: nil

    cond do
      is_binary(composer.active_tool) ->
        Styles.status_line(
          composer.status,
          composer.provider_down?,
          step,
          composer.tool_elapsed_s,
          "running #{composer.active_tool}",
          :chrome
        )

      Styles.busy?(composer.status) ->
        Styles.status_line(
          composer.status,
          composer.provider_down?,
          step,
          composer.silence_s,
          "thinking",
          :chrome
        )

      true ->
        Styles.status_line(composer.status, composer.provider_down?, nil, nil, nil, :chrome)
    end
  end
end
