defmodule CodingAgent.UI.ComposerTest do
  @moduledoc """
  The composer panel as a unit: `UI.Composer` owns the geometry (the
  measure side of `measure = paint`) and the look; the TUI only resolves
  the VALUES it is handed.

  These are pure assertions on the structs `placements/2` returns, so the
  layout can be verified without a terminal — the colour-level checks
  live in `tui_cells_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.UI.{Composer, Styles}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, Textarea}

  defp composer(opts \\ []), do: Composer.new(opts)

  describe "height/1 (the measure contract)" do
    test "an empty composer is the floor height, with room for the meta row" do
      assert Composer.height(composer()) == Composer.min_height()
      # 1 padding + 2 floor lines + 1 air + 1 meta + 1 padding
      assert Composer.min_height() == 6
    end

    test "grows one row per typed line" do
      ta = ExRatatui.textarea_new()
      ExRatatui.textarea_insert_str(ta, "a\nb\nc")

      # the floor is 2 lines, so a 3-line buffer adds exactly one row
      assert Composer.height(composer(textarea: ta)) == Composer.min_height() + 1
    end

    test "clamps at max_lines (a long buffer cannot eat the screen)" do
      ta = ExRatatui.textarea_new()
      ExRatatui.textarea_insert_str(ta, Enum.map_join(1..40, "\n", &"l#{&1}"))

      assert Composer.height(composer(textarea: ta, max_lines: 4)) == Composer.min_height() + 2
    end
  end

  describe "placements/2" do
    test "returns a fill, the textarea and the meta row, top to bottom" do
      rect = %Rect{x: 5, y: 10, width: 40, height: 6}

      [fill, text, meta] = Composer.placements(composer(), rect)

      assert {%Paragraph{block: %Block{}}, ^rect} = fill
      assert {%Textarea{}, text_rect} = text
      assert {%Paragraph{block: %Block{titles: [_identity, _status]}}, meta_rect} = meta

      # the fill covers the WHOLE rect; the fields sit inside one cell of
      # padding — the surface goes on past them
      assert text_rect.x == rect.x + 1
      assert text_rect.width == rect.width - 2
      # the fields do not touch the surface's bottom edge
      assert meta_rect.y + meta_rect.height < rect.y + rect.height
      assert text_rect.y > rect.y
    end

    test "the meta row is its own row, with a blank row of air above the text" do
      rect = %Rect{x: 0, y: 0, width: 40, height: 6}

      [_fill, text, meta] = Composer.placements(composer(), rect)

      {_text_widget, text_rect} = text
      {_meta_widget, meta_rect} = meta

      # the text gets the floor rows; then one blank air row; then the
      # meta row — each on its own row, never overpainted
      assert text_rect.height == 2
      assert meta_rect.height == 1
      assert meta_rect.y == text_rect.y + text_rect.height + 1
    end

    test "the fill's block is a borderless chrome surface (the 'no frame' report)" do
      %Paragraph{block: block} =
        elem(hd(Composer.placements(composer(), %Rect{width: 20, height: 6})), 0)

      assert block.borders == []
      assert block.style == Styles.surface_bg(:chrome)
    end

    test "the textarea carries the visible cursor and the stated text colour" do
      [_fill, {%Textarea{} = ta, _}, _meta] =
        Composer.placements(composer(), %Rect{width: 40, height: 6})

      assert ta.cursor_style.modifiers == [:reversed]
      assert ta.cursor_line_style.modifiers == []
      assert ta.style == Styles.role(:text, :chrome)
    end
  end

  describe "the meta row" do
    defp titles(opts) do
      %Paragraph{block: %Block{titles: titles}} =
        elem(Enum.at(Composer.placements(composer(opts), %Rect{width: 60, height: 6}), 2), 0)

      titles
    end

    test "identity on the left, status on the right, per-span roles" do
      [left, right] = titles(agent: "build", model: "glm", status: :idle)

      assert left.alignment == :left
      assert right.alignment == :right

      text = Enum.map_join(left.content.spans, "", & &1.content)
      # no "you" and no arrow: the field IS the input, the agent names
      # what will handle it
      assert text == "build · model glm"

      # every span names the chrome surface (the fill is explicit there)
      assert Enum.all?(left.content.spans, &(&1.style.bg == Styles.surface_bg(:chrome).bg))
    end

    test "no agent: the identity reads 'model …', with no placeholder arrow" do
      [left, _right] = titles(agent: nil, model: "glm")
      text = Enum.map_join(left.content.spans, "", & &1.content)
      assert text == "model glm"
    end

    test "the active tool names itself in the status" do
      [_left, right] = titles(status: :running, active_tool: "mix", tool_elapsed_s: 38)
      text = Enum.map_join(right.content.spans, "", & &1.content)
      assert text =~ "running mix"
      assert text =~ "38s"
    end

    test "a busy-but-silent turn shows the silence duration" do
      [_left, right] = titles(status: :running, silence_s: 12)
      text = Enum.map_join(right.content.spans, "", & &1.content)
      assert text =~ "thinking"
      assert text =~ "12s"
    end
  end
end
