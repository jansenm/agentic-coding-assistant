# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.OverlayTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.{LiveBand, Overlay, Stats}
  alias ExRatatui.Layout.Rect

  # The overlay geometry was a constant per call site before this module:
  # `area.height - 4` was the cap here and `area.height - h - 3` the offset
  # there, and a 26-row menu on a 30-row window came out at a negative row.
  # One definition, so these are the only numbers to check.

  defp area(w, h), do: %Rect{x: 0, y: 0, width: w, height: h}

  test "the room stops above the input, the band and the air rows around it" do
    # 30 rows, a 5-row composer (its floor), a 3-row band, 2 air rows
    assert Overlay.room(area(100, 30), 5) == 30 - 5 - LiveBand.height() - 2
  end

  test "the room never collapses below one row" do
    assert Overlay.room(area(100, 4), 10) == 1
  end

  test "a rect's bottom edge is the room's last row, never a negative y" do
    tall = Overlay.rect(area(100, 30), 5, 26, 60)

    assert tall.height == Overlay.room(area(100, 30), 5)
    assert tall.y == 0
    assert tall.y + tall.height == Overlay.room(area(100, 30), 5)
  end

  test "a rect is centred and keeps its requested height when it fits" do
    rect = Overlay.rect(area(100, 30), 5, 6, 60)

    assert rect.height == 6
    assert rect.width == 60
    assert rect.x == 20
    assert rect.y + rect.height == Overlay.room(area(100, 30), 5)
  end

  test "a rect is never wider than the window" do
    rect = Overlay.rect(area(40, 30), 5, 6, 200)
    assert rect.width == 40
    assert rect.x == 0
  end

  test "the dialog width is the reading measure plus the border, capped to the window" do
    assert Overlay.width(area(200, 30)) == Overlay.measure() + 2
    assert Overlay.width(area(50, 30)) == 46
  end

  # `UI.Stats` is the detail view of the same two mirrors the sidebar
  # shows; both read `UI.Format` for the spelling, so a number cannot read
  # differently in the two surfaces.
  describe "Stats.lines/1" do
    defp stats(opts \\ []) do
      Stats.new(
        Keyword.merge(
          [
            session_id: "tui-abc",
            timing: %{
              CodingAgent.Core.Session.Timing.new()
              | rounds: 3,
                llm_ms: 3_000,
                tool_ms: 600
            },
            usage: %{CodingAgent.Core.Session.Usage.new() | input_tokens: 12_400}
          ],
          opts
        )
      )
    end

    test "one padded row per fact, no colon (the label column IS the separator)" do
      lines = Stats.lines(stats())

      assert hd(lines) == " session  tui-abc"
      assert Enum.any?(lines, &(&1 =~ ~r/^ rounds\s+3 calls$/))
      assert Enum.any?(lines, &(&1 =~ ~r/^ tokens\s+12\.4k in/))
      assert Enum.any?(lines, &(&1 =~ "3.0 s"))
    end

    test "a cost of zero is not a row (no baseline yet)" do
      refute Enum.any?(Stats.lines(stats()), &(&1 =~ "cost"))
    end

    test "a sampled cost and balance do render" do
      usage = %{
        CodingAgent.Core.Session.Usage.new()
        | cost: 0.25,
          cost_basis: :billed,
          balance: %{remaining: 4.0}
      }

      lines = Stats.lines(stats(usage: usage))
      assert Enum.any?(lines, &(&1 =~ ~r/^ cost\s+\$0\.2500 \(billed\)$/))
      assert Enum.any?(lines, &(&1 =~ ~r/^ credits\s+\$4\.00$/))
    end

    test "the trailer row is a BUDGET: what it costs against the cap" do
      lines = Stats.lines(stats(trailer: {1_740, 4_096}))

      assert Enum.any?(lines, &(&1 =~ ~r/^ trailer\s+1\.7k of 4\.0k$/))

      # no request assembled yet: no row, like the cached-tokens row (a 0
      # would claim a measurement that has not happened)
      refute Enum.any?(Stats.lines(stats(trailer: {0, 4_096})), &(&1 =~ "trailer"))
      refute Enum.any?(Stats.lines(stats()), &(&1 =~ "trailer"))
    end
  end

  describe "Stats.write_file/2 and copy/2" do
    test "the file lands beside tui.log and its path is returned" do
      assert {:ok, file} = Stats.write_file("tui-x", "a\nb\n")

      # the state dir is where tui.log already lives (derived from the
      # store path / XDG_STATE_HOME), NOT a directory of our choosing
      assert file == Path.join(CodingAgent.Core.Config.state_dir(), "stats-tui-x.txt")
      on_exit(fn -> File.rm_rf!(file) end)

      assert File.read!(file) == "a\nb\n"
    end

    test "copy/2 is a no-op under test_mode (no clipboard in a test run)" do
      assert :ok = Stats.copy("x", true)
    end
  end
end
