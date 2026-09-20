defmodule CodingAgent.UI.Styles do
  @moduledoc """
  The one home for "how a piece of information looks" (presentation
  vocabulary).

  Call sites name a semantic ROLE and, when they paint on a non-default
  region, a SURFACE (`:base`, `:chrome`, `:sidebar`) — never a raw color.
  Changing what "muted" looks like is a one-line edit in
  `CodingAgent.UI.Palette`, and `:gray` vs `:dark_gray` stops being a
  per-author guess.

  The role/surface split exists because one colour cannot serve every
  region: `:muted` is `dark_gray` on the base surface, but the chrome and
  sidebar fills are *also* dark, so on those surfaces `:muted` must
  lighten (see `Palette`). A role used on a surface without that
  override would paint invisible text — the "grey bear in a snowstorm"
  bug — so the palette resolves per surface, and the test suite asserts,
  for every role x filled surface, that `fg != bg`.

  Rules this module encodes (see `code_review.md`, UI styling):

  - One meaning per role; call sites name the role (and surface).
  - All borders `:rounded`; the border color is chosen by role
    (`:accent` for focused/input, `:muted` for passive panels,
    `:warning` for the approval gate).
  - Identity (agent, model) always uses a badge.
  - Label/value rows always come from `definition_list/1`.

  Pure presentation: no config, no domain. A caller prepares a status
  struct and this module only paints it.
  """

  alias CodingAgent.UI.Palette
  alias ExRatatui.Style
  alias ExRatatui.Text
  alias ExRatatui.Widgets.Block

  @typedoc "A semantic style role (re-exported from `Palette`)."
  @type role :: Palette.role()

  @typedoc "A region the app paints on (re-exported from `Palette`)."
  @type surface :: Palette.surface()

  # The active palette. A module attribute today (the shipped scheme); a
  # future user theme merges into `Palette.default()` and is read here —
  # the seam already exists, so no call site changes.
  @palette Palette.default()

  @doc "The active palette (the seam a user theme would replace)."
  @spec palette() :: Palette.t()
  def palette, do: @palette

  # -- roles -----------------------------------------------------------------

  @doc """
  The `%Style{}` for a semantic role on a surface. The only place raw
  colors are chosen (via `Palette`). Unknown roles raise (a typo should
  not silently render default-styled).
  """
  @spec role(role(), surface()) :: Style.t()
  def role(name, surface \\ :base), do: Palette.resolve(palette(), name, surface)

  @doc """
  The full-surface style: the `:text` role on `surface`, including that
  surface's background. Use as a widget-level style for a body whose
  spans carry no roles of their own.
  """
  @spec surface(surface()) :: Style.t()
  def surface(name), do: role(:text, name)

  @doc """
  Background only: the surface's fill, no foreground, so a line's spans
  keep their own roles. Use as the widget style of a bar (e.g. the
  status row) whose spans are already role-styled.
  """
  @spec surface_bg(surface()) :: Style.t()
  def surface_bg(name), do: %Style{bg: Palette.fill(palette(), name)}

  # -- badges ----------------------------------------------------------------

  @typedoc "A badge kind: the identity label that precedes a value."
  @type badge_kind :: :agent | :model | :user | :session

  @doc """
  A badge: a muted kind label plus a role-colored value, as a
  line-like `%Text.Line{}` (usable in a `Block` title, a `Paragraph`, a
  table cell). `nil` values render as the bare label in `:muted` so a
  missing identity is honest, not blank.
  """
  @spec badge(badge_kind(), String.t() | nil, surface()) :: Text.Line.t()
  def badge(kind, value, surface \\ :base) do
    label = to_string(kind)
    value_style = badge_value_style(kind, surface)

    spans =
      case value do
        v when is_binary(v) and v != "" ->
          [
            Text.Span.new("#{label} ", style: role(:muted, surface)),
            Text.Span.new(v, style: value_style)
          ]

        _ ->
          [Text.Span.new(label, style: role(:muted, surface))]
      end

    Text.Line.new(spans)
  end

  defp badge_value_style(:agent, surface), do: role(:agent, surface)
  defp badge_value_style(:model, surface), do: role(:model, surface)
  defp badge_value_style(:user, surface), do: role(:user, surface)
  defp badge_value_style(_, surface), do: role(:text, surface)

  # -- definition list -------------------------------------------------------

  @doc """
  A key/value list for a `Paragraph`: each label in `:muted`, each value
  in `:text` (or a per-row role), one line per pair. Replaces the
  hand-assembled span/blank assembly in the sidebar (the code that
  drifted).

  A pair may be `{label, value}` or `{label, value, role}` — the role
  lets a warning row (e.g. context near the compaction threshold) keep
  its label muted while the value turns `:warning`.

  Labels are padded to the widest label in the list and joined to their
  value with a colon, so the values align in one column. A bare
  concatenation (`sessiontui-259`) is unreadable — the separator is the
  point of a definition list, not decoration.
  """
  @spec definition_list(
          [{String.t(), String.t()} | {String.t(), String.t(), role()}],
          surface()
        ) :: [Text.Line.t()]
  def definition_list(pairs, surface \\ :base) when is_list(pairs) do
    width =
      pairs
      |> Enum.map(fn
        {label, _, _} -> String.length(to_string(label))
        {label, _} -> String.length(to_string(label))
      end)
      |> Enum.max(fn -> 0 end)

    Enum.map(pairs, fn
      {label, value, value_role} ->
        definition_line(label, value, width, value_role, surface)

      {label, value} ->
        definition_line(label, value, width, :text, surface)
    end)
  end

  defp definition_line(label, value, width, value_role, surface) do
    label_span =
      label
      |> to_string()
      |> then(&String.pad_trailing("#{&1}:", width + 1))

    # label and value share the surface: the label is `:muted` ON that
    # surface (so its fg and bg match the value's, no invisible label)
    Text.Line.new([
      Text.Span.new(label_span <> " ", style: role(:muted, surface)),
      Text.Span.new(if(value in [nil, ""], do: "—", else: to_string(value)),
        style: role(value_role, surface)
      )
    ])
  end

  @doc "A single blank spacer line (one spacing token instead of ad-hoc empty lines)."
  @spec gap() :: Text.Line.t()
  def gap, do: Text.Line.new([Text.Span.new("", style: %Style{})])

  # -- panels and headers ----------------------------------------------------

  @doc """
  A titled panel `%Block{}`. Owns border type/color/placement so the
  transcript boxes, the sidebar and the dialogs stop each picking their
  own. `:titles` may carry `%Block.Title{}` for extra positions.

  Options:

    * `:title`, `:titles`, `:borders`, `:padding`
    * `:surface` — the region (`:base` default); sets the background of
      the panel and the title's role colors
    * `:border` — a role for the border color (default `:muted`); ignored
      when `:border_style` is given
    * `:border_style` — an explicit `%Style{}` (for a caller-owned border
      color); when omitted, `role(border, surface)` is used
    * `:border_type` — default `:rounded`; pass e.g. `:double` for a
      distinct surface (the approval gate)
    * `:title_position` — `:top` (default) or `:bottom`
    * `:title_alignment` — `:left` (default), `:center` or `:right`
    * `:title_style` — an explicit style; pass `nil` to let a title line
      carry its own per-span styles (a block title_style would override
      them). Defaults to `role(:muted, surface)`.
    * `:style` — the block's own area style; defaults to the surface's
      FILL. That default is load-bearing: a widget-level style only
      paints the rows the widget writes, so a bordered panel whose
      content is short would show terminal background between the
      titles. The block covers its whole rect.
  """
  @spec panel(keyword()) :: Block.t()
  def panel(opts \\ []) do
    surface = Keyword.get(opts, :surface, :base)

    border_style =
      case Keyword.fetch(opts, :border_style) do
        {:ok, style} -> style
        :error -> role(Keyword.get(opts, :border, :muted), surface)
      end

    %Block{
      title: Keyword.get(opts, :title),
      titles: Keyword.get(opts, :titles, []),
      borders: Keyword.get(opts, :borders, [:all]),
      border_type: Keyword.get(opts, :border_type, :rounded),
      border_style: border_style,
      title_position: Keyword.get(opts, :title_position, :top),
      title_alignment: Keyword.get(opts, :title_alignment, :left),
      title_style: Keyword.get(opts, :title_style, role(:muted, surface)),
      style: Keyword.get(opts, :style, surface_bg(surface)),
      padding: Keyword.get(opts, :padding, {0, 0, 0, 0})
    }
  end

  @doc "A muted, slightly emphasized line for a panel section."
  @spec section_header(String.t(), surface()) :: Text.Line.t()
  def section_header(text, surface \\ :base) do
    Text.Line.new([Text.Span.new(to_string(text), style: role(:muted, surface))])
  end

  # -- status badge ----------------------------------------------------------

  @typedoc "A status glyph + role + label, ready to compose into a line."
  @type status_badge_t :: %{glyph: String.t(), style: Style.t(), label: String.t()}

  @doc """
  The glyph, color role and label for a session status. One home for the
  status vocabulary (the render path keeps no glyph literals).

  Geometric Unicode only — emoji width is unreliable across terminals
  and breaks the single-line footer math.
  """
  @spec status_badge(atom(), boolean(), surface()) :: status_badge_t()
  def status_badge(status, provider_down? \\ false, surface \\ :base)

  def status_badge(:running, _down, surface),
    do: %{glyph: "●", style: role(:success, surface), label: "running…"}

  def status_badge(:interrupting, _down, surface),
    do: %{glyph: "◐", style: role(:warning, surface), label: "stopping…"}

  def status_badge(:idle, _down, surface),
    do: %{glyph: "○", style: role(:muted, surface), label: "idle"}

  def status_badge(:interrupted, _down, surface),
    do: %{glyph: "⏸", style: role(:warning, surface), label: "approval needed (y/n/e)"}

  def status_badge(:error, true, surface),
    do: %{glyph: "✖", style: role(:error, surface), label: "provider unavailable"}

  def status_badge(:error, false, surface),
    do: %{glyph: "✖", style: role(:error, surface), label: "error"}

  def status_badge(_, _down, surface),
    do: %{glyph: "?", style: role(:muted, surface), label: "unknown"}

  # -- spinner ---------------------------------------------------------------

  # Braille frames: single-width in practice and calm at ~8 fps. The
  # frame set is DATA (here), never a glyph literal in the render path.
  @braille_frames {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

  @doc """
  One spinner frame for the given step (cycles by remainder). Pure, so
  the animation is testable without a terminal.

  Pass `step` as `nil` for a static first frame (a non-animating caller).
  """
  @spec spinner(non_neg_integer() | nil) :: String.t()
  def spinner(nil), do: elem(@braille_frames, 0)

  def spinner(step) when is_integer(step) do
    elem(@braille_frames, rem(step, tuple_size(@braille_frames)))
  end

  @doc "The number of frames in the spinner cycle."
  @spec spinner_frames() :: pos_integer()
  def spinner_frames, do: tuple_size(@braille_frames)

  @doc """
  Whether a status means "work is in flight" — the spinner should run.
  Driven by status only; the *elapsed* time (in the caller) makes a
  silently stuck turn diverge from a healthy one.
  """
  @spec busy?(atom()) :: boolean()
  def busy?(status), do: status in [:running, :interrupting]

  @doc """
  The status line for the input box's top border: `⠋ running · 12s`.
  `elapsed_s` is nil (not shown) when the turn just started, so a fast
  turn never flashes a duration. `label` overrides the badge's default
  text (e.g. `"running mix"` while a tool is in flight).

  Returns a `%Text.Line{}` so it composes in a `Block.Title`, the same
  way the identity footer does.
  """
  @spec status_line(
          atom(),
          boolean(),
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          String.t() | nil,
          surface()
        ) :: Text.Line.t()
  def status_line(
        status,
        provider_down? \\ false,
        step \\ nil,
        elapsed_s \\ nil,
        label \\ nil,
        surface \\ :base
      ) do
    badge = status_badge(status, provider_down?, surface)

    glyph =
      if busy?(status) do
        spinner(step)
      else
        badge.glyph
      end

    elapsed =
      case elapsed_s do
        s when is_integer(s) and s > 0 -> " · #{s}s"
        _ -> ""
      end

    Text.Line.new([
      Text.Span.new(" #{glyph} ", style: badge.style),
      Text.Span.new((label || badge.label) <> elapsed, style: role(:muted, surface))
    ])
  end
end
