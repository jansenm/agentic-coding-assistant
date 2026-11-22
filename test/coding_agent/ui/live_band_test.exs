# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.LiveBandTest do
  @moduledoc """
  The live band as a unit: `UI.LiveBand` owns its geometry (the measure
  side of `measure = paint`) and its row composition; the TUI resolves
  the VALUES — the running identity, the status, the spinner step, the
  elapsed seconds — and hands them over.

  These are pure assertions on the structs `placements/2` returns, so the
  layout can be verified without a terminal — the colour-level checks
  live in `tui_cells_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.UI.{LiveBand, Styles}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text
  alias ExRatatui.Widgets.{Block, Paragraph}

  defp band(opts \\ []), do: LiveBand.new(opts)

  # the band's row as plain text (the same "what does it say" assertion
  # the composer tests make on a Block title's spans)
  defp row_text(opts) do
    [_fill, {%Paragraph{text: %Text.Line{spans: spans}}, _rect}] =
      LiveBand.placements(band(opts), %Rect{x: 0, y: 0, width: 60, height: 3})

    Enum.map_join(spans, "", & &1.content)
  end

  defp row_spans(opts) do
    [_fill, {%Paragraph{text: %Text.Line{spans: spans}}, _rect}] =
      LiveBand.placements(band(opts), %Rect{x: 0, y: 0, width: 60, height: 3})

    spans
  end

  describe "height/0 (the measure contract)" do
    test "one padding row, the status row, one padding row" do
      # at least one row of air on all four sides (owner requirement): the
      # two padding rows are up/down, `inset/1` is the left/right pair
      assert LiveBand.height() == 3
    end
  end

  describe "placements/2" do
    test "a full-rect base fill, then the row inset one cell on every side" do
      rect = %Rect{x: 5, y: 10, width: 40, height: 3}
      [fill, status] = LiveBand.placements(band(), rect)

      assert {%Paragraph{block: %Block{borders: [], style: fill_style}}, ^rect} = fill
      # the band takes the TRANSCRIPT's background (unpainted), not the
      # chrome grey of the composer below it — the fill covers the whole
      # rect, because a widget-level background would only paint the row
      # the status paragraph writes
      assert fill_style == Styles.surface_bg(:base)

      {widget, inner} = status
      assert %Paragraph{text: %Text.Line{}} = widget

      assert inner.x == rect.x + 1
      assert inner.y == rect.y + 1
      assert inner.width == rect.width - 2
      assert inner.height == 1
      # the row does not touch the rect's bottom edge either
      assert inner.y + inner.height < rect.y + rect.height
    end
  end

  describe "the row" do
    test "idle: the status alone — the setup row below already names the agent and model" do
      assert row_text([]) == "○ idle"
      assert row_text(status: :idle, agent: "build", model: "glm") == "○ idle"
    end

    test "a running turn: the running identity, then the spinner and the word" do
      # `label` is the caller's word for what the turn is DOING (the TUI
      # resolves it: "thinking" while the model is silent, "running mix"
      # while a tool is in flight) — the band only places it
      text = row_text(status: :running, agent: "build", model: "glm", spin: 2, label: "thinking")

      assert text == "agent build · model glm · #{Styles.spinner(2)} thinking"
    end

    test "with no caller label the badge's own word is used" do
      assert row_text(status: :running, spin: 0) == "#{Styles.spinner(0)} running…"
    end

    test "a running turn with no resolved identity: the status alone, no dangling separator" do
      assert row_text(status: :running, spin: 0, label: "thinking") ==
               "#{Styles.spinner(0)} thinking"

      text = row_text(status: :running, agent: "build", spin: 0, label: "thinking")
      assert text =~ "agent build · "
      refute text =~ "model "
    end

    test "a tool in flight names itself and shows its own runtime" do
      text =
        row_text(
          status: :running,
          agent: "build",
          label: "running mix",
          elapsed_s: 38
        )

      assert text =~ "running mix · 38s"
      assert text =~ "agent build · "
    end

    test "the silence duration rides the thinking label" do
      assert row_text(status: :running, label: "thinking", elapsed_s: 12) =~ "thinking · 12s"
      # a turn that just started flashes no duration (0 is "no seconds yet")
      refute row_text(status: :running, label: "thinking", elapsed_s: 0) =~ "0s"
    end

    test "an error keeps its glyph and word (a provider outage says so)" do
      assert row_text(status: :error) == "✖ error"
      assert row_text(status: :error, provider_down?: true) == "✖ provider unavailable"
    end

    test "the gate's pause is a status like any other" do
      assert row_text(status: :interrupted) == "⏸ approval needed (y/n/e)"
    end

    test "the status is always painted — the row is permanent, the layout never moves" do
      for status <- [:idle, :running, :interrupting, :interrupted, :error] do
        assert row_text(status: status) != ""
      end
    end

    test "every span is styled for the band's own surface" do
      spans = row_spans(status: :running, agent: "build", model: "glm", spin: 0)

      # no span carries the chrome fill: their backgrounds agree with the
      # band's (the roles are resolved for :base, so `:muted` is the dark
      # grey that belongs on an unpainted row — on the chrome fill it
      # would be invisible)
      assert Enum.all?(spans, &(&1.style.bg == Styles.surface_bg(:base).bg))

      assert Enum.map_join(spans, "", & &1.content) =~ "agent build"
    end
  end
end
