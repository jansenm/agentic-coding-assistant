defmodule CodingAgent.UI.Palette do
  @moduledoc """
  The colour scheme as DATA, in layers (presentation only).

  A palette resolves a semantic ROLE on a SURFACE to a `%Style{}`. The
  layering is what lets a scheme be built top-down — base first, then
  surface refinements — and, one day, merged with a user's own scheme
  without touching a single call site:

    1. **Base** (`:base` role -> `%{fg, modifiers}`): what each role
       means, independent of where it is painted.
    2. **Overrides** (`surface -> role -> fg`): only the roles that must
       differ *on that surface*; anything absent inherits the base.
    3. **Fills** (`surface -> bg`): the surface's own background, or
       `nil` for the terminal default.

  Modifiers are a property of the ROLE (reasoning is italic, emphasis
  bold); only the colour is surface-dependent. So a theme may recolour
  without losing meaning.

  The point of the split is the grey-bear bug it prevents: `:muted` is
  `dark_gray` on the base surface, but the chrome/sidebar fills are
  *also* dark, so `:muted` is overridden to a lighter `:gray` there. A
  palette with no such override would paint invisible text; the test
  suite asserts, for every role x filled surface, that `fg != bg`.

  ## Named colours vs indexed colours (the "tempered white" report)

  A named ANSI colour is not a colour, it is a *slot in the user's
  theme*: `:white` is ANSI 15, and what that renders as is the
  terminal's business (the observed theme put it near `#c0c0c0`, which
  read as washed-out grey). An `{:indexed, n}` / `{:rgb, r, g, b}`
  value is stated outright: the cell carries it and no theme can soften
  it. So the fills and the body text — the two things the owner reads
  for hours — are stated, while the *semantic* colours (warning, error,
  agent, model) stay named, because their meaning is exactly "whatever
  this terminal calls yellow/red".

  That is the trade: pinned colours cost theme-adaptivity, so they are
  spent only on contrast.
  """

  alias ExRatatui.Style

  @typedoc "A semantic role name (colour-independent)."
  @type role ::
          :text
          | :muted
          | :emphasis
          | :info
          | :success
          | :warning
          | :error
          | :agent
          | :model
          | :user
          | :accent
          | :reasoning

  @typedoc "A region the app paints on."
  @type surface :: :base | :chrome | :sidebar

  @typedoc """
  A colour: a named ANSI atom, or an explicit indexed/RGB value.

  Explicit values are how the scheme gets a contrast the terminal's own
  theme cannot override — see the moduledoc.
  """
  @type color :: atom() | {:indexed, 0..255} | {:rgb, 0..255, 0..255, 0..255}

  @type t :: %__MODULE__{
          base: %{role() => %{fg: color(), modifiers: [atom()]}},
          overrides: %{surface() => %{role() => color()}},
          fills: %{surface() => color() | nil}
        }

  defstruct base: %{}, overrides: %{}, fills: %{}

  # ANSI 8 / ANSI 15 are theme slots; these are the greys this app paints
  # itself. 235 is #262626 (~90% black) — the owner's "90% grey", dark
  # enough to read as a surface instead of as "just grey" on a dark
  # terminal. 255 is #eeeeee: a soft white, one step off pure white so
  # long text does not glare.
  @surface_grey {:indexed, 235}
  @body_white {:indexed, 255}

  @doc """
  The shipped scheme. `:base` is the terminal-default surface (no fill,
  the transcript); `:chrome` is every region the app PAINTS ITSELF — the
  overlays (menu, picker, dialog, status row) and the composer field; the
  fills are the point: one grey, so the chrome reads as one material and
  the composer sits on it like the rest of the frame. `:sidebar` is the
  status panel, on the same grey.

  The dark fills are why `:muted`/`:info`/`:reasoning` lighten on those
  surfaces.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      base: %{
        # the body text: stated, not themed (a theme's "white" slot read
        # as tempered grey — see the moduledoc)
        text: %{fg: @body_white},
        muted: %{fg: :dark_gray},
        emphasis: %{fg: @body_white, modifiers: [:bold]},
        info: %{fg: :dark_gray},
        success: %{fg: :light_green},
        warning: %{fg: :yellow},
        error: %{fg: :red},
        agent: %{fg: :cyan, modifiers: [:bold]},
        model: %{fg: :light_cyan},
        user: %{fg: :magenta, modifiers: [:bold]},
        accent: %{fg: :cyan, modifiers: [:bold]},
        reasoning: %{fg: :dark_gray, modifiers: [:italic]}
      },
      overrides: %{
        # on a dark fill, the dark-grey roles must lighten or vanish
        chrome: %{muted: :gray, info: :gray, reasoning: :gray},
        sidebar: %{muted: :gray, info: :gray, reasoning: :gray}
      },
      fills: %{base: nil, chrome: @surface_grey, sidebar: @surface_grey}
    }
  end

  @doc """
  Resolves `role` on `surface` to a full `%Style{}` (fg, that surface's
  bg, and the role's intrinsic modifiers).
  """
  @spec resolve(t(), role(), surface()) :: Style.t()
  def resolve(%__MODULE__{} = palette, role, surface) do
    base =
      case Map.fetch(palette.base, role) do
        {:ok, base} -> base
        :error -> raise ArgumentError, "unknown style role: #{inspect(role)}"
      end

    fg = get_in(palette.overrides, [surface, role]) || base.fg

    bg =
      case Map.fetch(palette.fills, surface) do
        {:ok, bg} -> bg
        :error -> raise ArgumentError, "unknown style surface: #{inspect(surface)}"
      end

    %Style{fg: fg, bg: bg, modifiers: Map.get(base, :modifiers, [])}
  end

  @doc """
  Layers `over` on top of `base`, per field: roles and surfaces not
  mentioned by `over` keep `base`'s value. This is the user-theme seam —
  a scheme author names only what differs (base colours first, then the
  surface refinements) and inherits the rest.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = over) do
    %__MODULE__{
      base: deep_merge_map(base.base, over.base),
      overrides: deep_merge_map(base.overrides, over.overrides),
      fills: Map.merge(base.fills, over.fills)
    }
  end

  defp deep_merge_map(a, b) do
    Map.merge(a, b, fn _k, va, vb ->
      if is_map(va) and is_map(vb), do: Map.merge(va, vb), else: vb
    end)
  end

  @doc "The fill colour of a surface (`nil` = terminal default)."
  @spec fill(t(), surface()) :: color() | nil
  def fill(%__MODULE__{fills: fills}, surface), do: Map.fetch!(fills, surface)

  @doc "Whether `surface` has a non-default fill."
  @spec filled?(t(), surface()) :: boolean()
  def filled?(palette, surface), do: fill(palette, surface) != nil
end
