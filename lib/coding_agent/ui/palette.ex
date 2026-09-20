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

  @type t :: %__MODULE__{
          base: %{role() => %{fg: atom(), modifiers: [atom()]}},
          overrides: %{surface() => %{role() => atom()}},
          fills: %{surface() => atom() | nil}
        }

  defstruct base: %{}, overrides: %{}, fills: %{}

  @doc """
  The shipped scheme. `:base` is the terminal-default surface (no fill,
  the transcript); `:chrome` is every overlay (menu, picker, dialog,
  status row, input box); `:sidebar` is the status panel. The dark fills
  of chrome/sidebar are why `:muted`/`:info`/`:reasoning` lighten there.
  """
  @spec default() :: t()
  def default do
    %__MODULE__{
      base: %{
        text: %{fg: :white},
        muted: %{fg: :dark_gray},
        emphasis: %{fg: :white, modifiers: [:bold]},
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
      fills: %{base: nil, chrome: :dark_gray, sidebar: :dark_gray}
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
  @spec fill(t(), surface()) :: atom() | nil
  def fill(%__MODULE__{fills: fills}, surface), do: Map.fetch!(fills, surface)

  @doc "Whether `surface` has a non-default fill."
  @spec filled?(t(), surface()) :: boolean()
  def filled?(palette, surface), do: fill(palette, surface) != nil
end
