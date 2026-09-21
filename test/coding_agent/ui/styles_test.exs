defmodule CodingAgent.UI.StylesTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.{Palette, Styles}
  alias ExRatatui.Text

  @roles [
    :text,
    :muted,
    :emphasis,
    :user,
    :agent,
    :model,
    :accent,
    :reasoning,
    :info,
    :warning,
    :error,
    :success
  ]

  @surfaces [:base, :chrome, :sidebar]

  describe "roles" do
    test "every role on every surface returns a %Style{}; unknown roles raise" do
      for role <- @roles, surface <- @surfaces do
        assert %ExRatatui.Style{} = Styles.role(role, surface)
      end

      bad = String.to_atom("not_a_role")
      assert_raise ArgumentError, fn -> Styles.role(bad) end
    end

    test "muted is dark_gray on the base surface" do
      assert Styles.role(:muted).fg == :dark_gray
    end

    test "the palette never paints a role in its own surface's fill" do
      # The grey-bear invariant: for every role on every FILLED surface,
      # the foreground must differ from the background. A new role or
      # surface that collides fails here, not in the user's eyes.
      palette = Styles.palette()

      for role <- @roles, surface <- @surfaces, Palette.filled?(palette, surface) do
        style = Styles.role(role, surface)

        assert style.fg != style.bg,
               "#{inspect(role)} on #{surface}: fg == bg (#{inspect(style.fg)})"
      end
    end

    test "the composer field is legible against its own fill" do
      # the composer is the one surface the user types ON for hours: its
      # text must be both distinct from the fill and a real white (an
      # ANSI 15 "white" is a theme slot, and the observed theme rendered
      # it as washed-out grey — the "tempered" report)
      palette = Styles.palette()
      fill = Palette.fill(palette, :chrome)
      text = Styles.role(:text, :chrome)

      assert text.bg == fill
      assert text.fg != fill
      assert {:indexed, _} = text.fg
    end
  end

  describe "badge/2" do
    test "a badge is a label plus a role-colored value" do
      %Text.Line{spans: [label, value]} = Styles.badge(:agent, "plan")
      assert label.content == "agent "
      assert label.style == Styles.role(:muted)
      assert value.content == "plan"
      assert value.style == Styles.role(:agent)
    end

    test "a nil value renders the bare label in muted (honest, not blank)" do
      %Text.Line{spans: [only]} = Styles.badge(:agent, nil)
      assert only.content == "agent"
      assert only.style == Styles.role(:muted)
    end

    test "the value role is per-kind (agent cyan, model legible on chrome)" do
      %Text.Line{spans: [_, a]} = Styles.badge(:agent, "build", :chrome)
      %Text.Line{spans: [_, m]} = Styles.badge(:model, "glm", :chrome)
      assert a.style == Styles.role(:agent, :chrome)
      assert m.style == Styles.role(:model, :chrome)
      # the model id sits on the chrome fill (the grey the composer and
      # every overlay share); its own color must differ from the fill,
      # or it vanishes
      assert Styles.role(:model, :chrome).fg != Styles.surface_bg(:chrome).bg
    end
  end

  describe "definition_list/1" do
    test "label muted, value styled; nil value renders an em dash" do
      [row] = Styles.definition_list([{"effort", "default"}])
      assert %Text.Line{spans: [label, value]} = row
      assert label.style == Styles.role(:muted)
      assert value.style == Styles.role(:text)

      [nil_row] = Styles.definition_list([{"cost", nil}])
      assert %Text.Line{spans: [_, v]} = nil_row
      assert v.content == "—"
    end

    test "the label carries a colon separator (no bare concatenation)" do
      # Regression (review E): the rendered row must not read
      # "sessiontui-259" — the separator is the point of the primitive.
      [row] = Styles.definition_list([{"session", "tui-259"}])
      rendered = row.spans |> Enum.map_join(& &1.content)
      assert rendered == "session: tui-259"
    end

    test "values align: labels pad to the widest in the list" do
      rows = Styles.definition_list([{"session", "a"}, {"compacts at", "b"}])
      rendered = Enum.map(rows, &Enum.map_join(&1.spans, "", fn s -> s.content end))
      assert rendered == ["session:     a", "compacts at: b"]
    end

    test "a three-tuple carries a per-row value role (the warning case)" do
      [row] = Styles.definition_list([{"context", "480k", :warning}])
      assert %Text.Line{spans: [_, value]} = row
      assert value.style == Styles.role(:warning)
    end
  end

  describe "status_badge/2" do
    test "maps each status to a glyph, role and label" do
      assert %{glyph: "●", label: "running…"} = Styles.status_badge(:running)
      assert %{glyph: "◐"} = Styles.status_badge(:interrupting)
      assert %{glyph: "○", style: s} = Styles.status_badge(:idle)
      assert s == Styles.role(:muted)
      assert %{glyph: "⏸"} = Styles.status_badge(:interrupted)
      assert %{label: "error"} = Styles.status_badge(:error, false)
      assert %{label: "provider unavailable"} = Styles.status_badge(:error, true)
    end
  end

  describe "panel/1" do
    test "rounded borders, role border color, title style" do
      block = Styles.panel(title: " status ", border: :accent)
      assert block.border_type == :rounded
      assert block.border_style == Styles.role(:accent)
      assert block.title == " status "
      assert block.title_style == Styles.role(:muted)
    end

    test "an explicit border_style and a nil title_style are honored" do
      explicit = Styles.role(:warning)
      block = Styles.panel(border_style: explicit, title_style: nil)
      assert block.border_style == explicit
      assert block.title_style == nil
    end

    test "title position/alignment and border type are options (review A)" do
      block =
        Styles.panel(
          title: "build · model glm",
          title_position: :bottom,
          title_alignment: :right,
          border_type: :double
        )

      assert block.title_position == :bottom
      assert block.title_alignment == :right
      assert block.border_type == :double
    end
  end
end
