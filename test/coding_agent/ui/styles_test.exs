defmodule CodingAgent.UI.StylesTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Styles
  alias ExRatatui.Text

  describe "roles" do
    test "every role returns a %Style{} and unknown roles raise" do
      for role <- [
            :muted,
            :value,
            :user,
            :agent,
            :model,
            :accent,
            :reasoning,
            :info,
            :warning,
            :error,
            :success
          ] do
        assert %ExRatatui.Style{} = Styles.role(role)
      end

      bad = String.to_atom("not_a_role")
      assert_raise ArgumentError, fn -> Styles.role(bad) end
    end

    test "muted is one role (no gray/dark_gray split)" do
      assert Styles.role(:muted).fg == :dark_gray
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

    test "the value role is per-kind (agent cyan, model muted)" do
      %Text.Line{spans: [_, a]} = Styles.badge(:agent, "build")
      %Text.Line{spans: [_, m]} = Styles.badge(:model, "glm")
      assert a.style == Styles.role(:agent)
      assert m.style == Styles.role(:model)
    end
  end

  describe "definition_list/1" do
    test "label muted, value styled; nil value renders an em dash" do
      [row] = Styles.definition_list([{"effort", "default"}])
      assert %Text.Line{spans: [label, value]} = row
      assert label.style == Styles.role(:muted)
      assert value.style == Styles.role(:value)

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
          title: "you → build",
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
