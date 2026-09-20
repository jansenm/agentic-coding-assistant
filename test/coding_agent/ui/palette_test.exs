defmodule CodingAgent.UI.PaletteTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Palette

  test "default/0 is the shipping scheme with three surfaces" do
    p = Palette.default()
    assert Map.keys(p.fills) |> Enum.sort() == [:base, :chrome, :sidebar]
    assert Palette.fill(p, :base) == nil
    assert Palette.fill(p, :chrome) == :dark_gray
    assert Palette.fill(p, :sidebar) == :dark_gray
    refute Palette.filled?(p, :base)
    assert Palette.filled?(p, :chrome)
  end

  test "resolution: base roles on the base surface carry no fill" do
    p = Palette.default()
    style = Palette.resolve(p, :muted, :base)
    assert style.fg == :dark_gray
    assert style.bg == nil
  end

  test "surface overrides win only where declared; the rest inherit the base" do
    p = Palette.default()

    # declared override: muted lightens on chrome
    assert Palette.resolve(p, :muted, :chrome).fg == :gray
    # not overridden: agent keeps its base color on chrome
    assert Palette.resolve(p, :agent, :chrome).fg == Palette.resolve(p, :agent, :base).fg
  end

  test "modifiers belong to the role, not the surface" do
    p = Palette.default()
    assert :italic in Palette.resolve(p, :reasoning, :base).modifiers
    assert :italic in Palette.resolve(p, :reasoning, :sidebar).modifiers
    assert :bold in Palette.resolve(p, :emphasis, :chrome).modifiers
  end

  test "a custom palette layers over the default (the user-theme seam)" do
    # simulate a future user scheme: one base recolor and one override
    user = %Palette{
      base: %{model: %{fg: :light_magenta}},
      overrides: %{chrome: %{agent: :light_blue}},
      fills: %{}
    }

    custom = Palette.merge(Palette.default(), user)

    # the user's changes win...
    assert Palette.resolve(custom, :model, :base).fg == :light_magenta
    assert Palette.resolve(custom, :agent, :chrome).fg == :light_blue
    # ...and everything they did not name still inherits the default
    assert Palette.resolve(custom, :muted, :chrome).fg == :gray
    assert Palette.resolve(custom, :agent, :base).fg == :cyan
    assert Palette.fill(custom, :chrome) == :dark_gray
  end

  test "unknown role and surface raise ArgumentError" do
    p = Palette.default()
    assert_raise ArgumentError, fn -> Palette.resolve(p, :nope, :base) end
    assert_raise ArgumentError, fn -> Palette.resolve(p, :text, :nope) end
  end
end
