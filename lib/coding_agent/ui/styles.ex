defmodule CodingAgent.UI.Styles do
  @moduledoc """
  The one home for "how a piece of information looks" (presentation
  vocabulary).

  Call sites name a semantic ROLE, never a raw color. Changing what
  "muted" looks like is then a one-line edit here, and `:gray` vs
  `:dark_gray` stops being a per-author guess. This is deliberately not a
  theme: there is one palette, no config surface.

  Rules this module encodes (see `code_review.md`, UI styling):

  - One meaning per color role; call sites name the role.
  - All borders `:rounded`; the border color is chosen by role
    (`:accent` for focused/input, `:muted` for passive panels,
    `:warning` for the approval gate).
  - Muted text is one role (`:muted`); there is no `:gray`/`:dark_gray`
    split.
  - Identity (agent, model) always uses a badge.
  - Label/value rows always come from `definition_list/1`.

  Pure presentation: no config, no domain. A caller prepares a status
  struct and this module only paints it.

  ## Deliberate role aliases

  Two roles currently resolve to the same `%Style{}` as another. That is
  intentional, not an oversight — kept as distinct roles so the next
  author can change one without moving the other:

  - `:info` == `:muted`: informational transcript lines are muted.
  - `:agent` == `:accent`: the agent hue doubles as the focused-chrome
    hue. They are separate roles because "who answered" and "what is
    focused" are different meanings that happen to share a colour today.

  If you change one of a pair, decide explicitly whether the other moves
  with it; the role names are the place to record that decision.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text
  alias ExRatatui.Widgets.Block

  # -- roles -----------------------------------------------------------------

  @typedoc "A semantic style role."
  @type role ::
          :muted
          | :value
          | :user
          | :agent
          | :model
          | :accent
          | :reasoning
          | :info
          | :warning
          | :error
          | :success

  @doc """
  The `%Style{}` for a semantic role. This is the only place raw colors
  are chosen. Unknown roles raise (a typo should not silently render
  default-styled).
  """
  @spec role(role()) :: Style.t()
  def role(:muted), do: %Style{fg: :dark_gray}
  def role(:value), do: %Style{fg: :white}
  def role(:user), do: %Style{fg: :magenta, modifiers: [:bold]}
  def role(:agent), do: %Style{fg: :cyan, modifiers: [:bold]}
  # NOT `:muted`: the model id sits on the input box's border, whose
  # chrome background is `:dark_gray` — muted (= dark_gray) was invisible
  # there ("grey bear in a snowstorm", found live). A distinct, legible
  # value color, matching the other identity roles.
  def role(:model), do: %Style{fg: :light_cyan}
  def role(:accent), do: %Style{fg: :cyan, modifiers: [:bold]}
  def role(:reasoning), do: %Style{fg: :dark_gray, modifiers: [:italic]}
  def role(:info), do: %Style{fg: :dark_gray}
  def role(:warning), do: %Style{fg: :yellow}
  def role(:error), do: %Style{fg: :red}
  def role(:success), do: %Style{fg: :light_green}

  def role(other) do
    raise ArgumentError, "unknown style role: #{inspect(other)}"
  end

  # -- badges ----------------------------------------------------------------

  @typedoc "A badge kind: the identity label that precedes a value."
  @type badge_kind :: :agent | :model | :user | :session

  @doc """
  A badge: a muted kind label plus a role-colored value, as a
  line-like `%Text.Line{}` (usable in a `Block` title, a `Paragraph`, a
  table cell). `nil` values render as the bare label in `:muted` so a
  missing identity is honest, not blank.

  The value color is the identity role: `:agent` for agents, `:model`
  for models, `:user` for the user, `:value` for anything else.
  """
  @spec badge(badge_kind(), String.t() | nil) :: Text.Line.t()
  def badge(kind, value) do
    label = to_string(kind)
    value_style = badge_value_style(kind)

    spans =
      case value do
        v when is_binary(v) and v != "" ->
          [
            Text.Span.new("#{label} ", style: role(:muted)),
            Text.Span.new(v, style: value_style)
          ]

        _ ->
          [Text.Span.new(label, style: role(:muted))]
      end

    Text.Line.new(spans)
  end

  defp badge_value_style(:agent), do: role(:agent)
  defp badge_value_style(:model), do: role(:model)
  defp badge_value_style(:user), do: role(:user)
  defp badge_value_style(_), do: role(:value)

  # -- definition list -------------------------------------------------------

  @doc """
  A key/value list for a `Paragraph`: each label in `:muted`, each value
  in `:value` (or a per-row role), one line per pair. Replaces the
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
  @spec definition_list([{String.t(), String.t()} | {String.t(), String.t(), role()}]) ::
          [Text.Line.t()]
  def definition_list(pairs) when is_list(pairs) do
    width =
      pairs
      |> Enum.map(fn
        {label, _, _} -> String.length(to_string(label))
        {label, _} -> String.length(to_string(label))
      end)
      |> Enum.max(fn -> 0 end)

    Enum.map(pairs, fn
      {label, value, value_role} -> definition_line(label, value, width, role(value_role))
      {label, value} -> definition_line(label, value, width, role(:value))
    end)
  end

  defp definition_line(label, value, width, style) do
    label_span =
      label
      |> to_string()
      |> then(&String.pad_trailing("#{&1}:", width + 1))

    Text.Line.new([
      Text.Span.new(label_span <> " ", style: role(:muted)),
      Text.Span.new(if(value in [nil, ""], do: "—", else: to_string(value)), style: style)
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
    * `:border` — a role for the border style (default `:muted`); ignored
      when `:border_style` is given
    * `:border_style` — an explicit `%Style{}` (for a caller-owned border
      color); when omitted, `role(border)` is used
    * `:border_type` — default `:rounded`; pass e.g. `:double` for a
      distinct surface (the approval gate)
    * `:title_position` — `:top` (default) or `:bottom`
    * `:title_alignment` — `:left` (default), `:center` or `:right`
    * `:title_style` — an explicit style; pass `nil` to let a title line
      carry its own per-span styles (a block title_style would override
      them). Defaults to `role(:muted)`.
  """
  @spec panel(keyword()) :: Block.t()
  def panel(opts \\ []) do
    border_style =
      case Keyword.fetch(opts, :border_style) do
        {:ok, style} -> style
        :error -> role(Keyword.get(opts, :border, :muted))
      end

    %Block{
      title: Keyword.get(opts, :title),
      titles: Keyword.get(opts, :titles, []),
      borders: Keyword.get(opts, :borders, [:all]),
      border_type: Keyword.get(opts, :border_type, :rounded),
      border_style: border_style,
      title_position: Keyword.get(opts, :title_position, :top),
      title_alignment: Keyword.get(opts, :title_alignment, :left),
      title_style: Keyword.get(opts, :title_style, role(:muted)),
      padding: Keyword.get(opts, :padding, {0, 0, 0, 0})
    }
  end

  @doc "A muted, slightly emphasized line for a panel section."
  @spec section_header(String.t()) :: Text.Line.t()
  def section_header(text) do
    Text.Line.new([Text.Span.new(to_string(text), style: role(:muted))])
  end

  # -- chrome (overlay backgrounds) ------------------------------------------

  @doc """
  The chrome background for overlays (menu, dialog, status row): readable
  text on the app's dark panel fill, so an overlay is legible over the
  transcript. `fg` is the `:value` role's color.
  """
  @spec chrome() :: Style.t()
  def chrome, do: %Style{fg: :white, bg: :dark_gray}

  @doc "Chrome variant with an explicit foreground role (e.g. a warning border)."
  @spec chrome(role()) :: Style.t()
  def chrome(fg_role) do
    %Style{role(fg_role) | bg: :dark_gray}
  end

  @doc "Chrome background only, no foreground: a full-width bar whose spans carry their own roles."
  @spec chrome_bg() :: Style.t()
  def chrome_bg, do: %Style{bg: :dark_gray}

  # -- status badge ----------------------------------------------------------

  @typedoc "A status glyph + role + label, ready to compose into a line."
  @type status_badge_t :: %{glyph: String.t(), style: Style.t(), label: String.t()}

  @doc """
  The glyph, color role and label for a session status. One home for the
  status vocabulary (the render path keeps no glyph literals).

  Geometric Unicode only — emoji width is unreliable across terminals
  and breaks the single-line footer math.
  """
  @spec status_badge(atom(), boolean()) :: status_badge_t()
  def status_badge(status, provider_down? \\ false)

  def status_badge(:running, _down), do: %{glyph: "●", style: role(:success), label: "running…"}

  def status_badge(:interrupting, _down),
    do: %{glyph: "◐", style: role(:warning), label: "stopping…"}

  def status_badge(:idle, _down), do: %{glyph: "○", style: role(:muted), label: "idle"}

  def status_badge(:interrupted, _down),
    do: %{glyph: "⏸", style: role(:warning), label: "approval needed (y/n/e)"}

  def status_badge(:error, true),
    do: %{glyph: "✖", style: role(:error), label: "provider unavailable"}

  def status_badge(:error, false), do: %{glyph: "✖", style: role(:error), label: "error"}
  def status_badge(_, _down), do: %{glyph: "?", style: role(:muted), label: "unknown"}

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
          String.t() | nil
        ) :: Text.Line.t()
  def status_line(status, provider_down? \\ false, step \\ nil, elapsed_s \\ nil, label \\ nil) do
    badge = status_badge(status, provider_down?)

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
      Text.Span.new((label || badge.label) <> elapsed, style: role(:muted))
    ])
  end
end
