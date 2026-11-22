# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.RegionTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Region

  # `Region` is the pure half of `move_region`: anchors in, two texts out.
  # Every refusal is pinned here, because a move that guesses is worse than
  # a move that refuses.

  defp file(body), do: body

  describe "the happy paths (cross-file)" do
    setup do
      source =
        file("""
        aaa
        defp one do
          1
        end
        bbb
        """)

      dest =
        file("""
        head
        tail
        """)

      {:ok, source: source, dest: dest}
    end

    test "before an anchor", %{source: source, dest: dest} do
      assert {:ok, out} =
               Region.move(source, dest, "defp one do", "end", {:before, "head"})

      assert out.dest == "defp one do\n  1\nend\nhead\ntail\n"
      assert out.source == "aaa\nbbb\n"
      assert out.region == 3
    end

    test "after an anchor", %{source: source, dest: dest} do
      assert {:ok, out} = Region.move(source, dest, "defp one do", "end", {:after, "head"})
      assert out.dest == "head\ndefp one do\n  1\nend\ntail\n"
    end

    test "at the beginning", %{source: source, dest: dest} do
      assert {:ok, out} = Region.move(source, dest, "defp one do", "end", :begin)
      assert String.starts_with?(out.dest, "defp one do")
    end

    test "at the end", %{source: source, dest: dest} do
      assert {:ok, out} = Region.move(source, dest, "defp one do", "end", :end)
      assert String.ends_with?(out.dest, "end\n")
      assert out.dest == "head\ntail\ndefp one do\n  1\nend\n"
    end

    test "a destination with no trailing newline gets one before the region" do
      assert {:ok, out} = Region.move("x\ny\n", "head", "x", "x", :end)
      assert out.dest == "head\nx\n"
    end
  end

  describe "the region is line-aligned" do
    test "it starts at the beginning of the anchor's line and ends at the end of the last one" do
      source = "alpha\n  defp f do\n    1\n  end\nomega\n"

      # anchors INSIDE the lines: the region is still whole lines, and it
      # runs through the line the `to` anchor ends on (here: omega's)
      assert {:ok, out} = Region.move(source, "z\n", "defp f", "end\nomega", :end)
      assert out.source == "alpha\n"
      assert out.dest == "z\n  defp f do\n    1\n  end\nomega\n"
      assert out.region == 4
    end

    test "a region that ends the file without a trailing newline still moves" do
      assert {:ok, out} = Region.move("keep\nlast", "z\n", "last", "last", :end)
      assert out.source == "keep\n"
      assert out.dest == "z\nlast"
    end
  end

  describe "refusals name the problem" do
    test "an ambiguous from anchor lists the lines" do
      assert {:error, message} = Region.move("a\nend\nb\nend\n", "z\n", "end", "end", :end)
      assert message =~ "2 matches for the `from` anchor"
      assert message =~ "on lines 2, 4"
    end

    test "a missing anchor says so" do
      assert {:error, message} = Region.move("a\n", "z\n", "nope", "a", :end)
      assert message =~ "`from` anchor not found"
    end

    test "the to anchor must come after the from anchor" do
      # the region's end cannot precede its start
      assert {:error, message} = Region.move("aaa\nbbb\n", "z\n", "bbb", "zzz", :end)
      assert message =~ "`to` anchor not found after the `from` anchor"
    end

    test "an empty anchor is refused" do
      assert {:error, message} = Region.move("a\n", "z\n", "", "a", :end)
      assert message =~ "must be a non-empty string"
    end

    test "the destination anchor must be unique" do
      assert {:error, message} = Region.move("a\n", "x\nx\n", "a", "a", {:before, "x"})
      assert message =~ "2 matches for the `position` anchor"
    end

    test "an unknown position is refused, listing the four" do
      assert {:error, message} = Region.move("a\n", "z\n", "a", "a", {:sideways, "z"})
      assert message =~ "unknown position"
      assert message =~ ":begin"
    end
  end

  # Same-file positions are resolved in the ORIGINAL text, so "inside the
  # region" is a closed interval. Both ends must be refused: `o == e` is
  # `{:after, <the region's last line>}`, the commonest no-op of all.
  describe "a same-file move refuses a position inside the region" do
    setup do
      source = "aaa\ndefp one do\n  1\nend\nbbb\n"
      {:ok, source: source}
    end

    test "o == s (before the region's own first line)", %{source: source} do
      assert {:error, message} =
               Region.move(source, source, "defp one do", "end", {:before, "defp one do"},
                 same_file?: true
               )

      assert message =~ "lands inside the region"
    end

    test "o == e (after the region's own last line)", %{source: source} do
      assert {:error, message} =
               Region.move(source, source, "defp one do", "end\nbbb", {:after, "end\nbbb"},
                 same_file?: true
               )

      assert message =~ "lands inside the region"
    end

    test "a region at the top cannot be moved to :begin", %{source: _} do
      top = "defp one do\n  1\nend\naaa\n"

      assert {:error, message} =
               Region.move(top, top, "defp one do", "end", :begin, same_file?: true)

      assert message =~ "lands inside the region"
    end

    test "a region at the end cannot be moved to :end", %{source: _} do
      bottom = "aaa\ndefp one do\n  1\nend\n"

      assert {:error, message} =
               Region.move(bottom, bottom, "defp one do", "end", :end, same_file?: true)

      assert message =~ "lands inside the region"
    end

    test "moving it EARLIER works", %{source: source} do
      assert {:ok, out} =
               Region.move(source, source, "defp one do", "end\n", :begin, same_file?: true)

      assert out.source == "defp one do\n  1\nend\naaa\nbbb\n"
      assert out.source == out.dest
    end

    test "moving it LATER works", %{source: source} do
      assert {:ok, out} =
               Region.move(source, source, "aaa\n", "aaa\n", :end, same_file?: true)

      assert out.source == "defp one do\n  1\nend\nbbb\naaa\n"
    end
  end

  # The check whose absence let a half-deleted block reach the compiler,
  # where the error surfaced hundreds of lines away from the damage.
  describe "the parse guard" do
    test "a region that is not a complete unit is refused" do
      source = "defp f do\n  1\nend\n\ndefp g do\n  2\nend\n"

      # `to` stops before the module's `end`, so the result has an
      # unclosed `do`
      assert {:error, message} =
               Region.move(source, "x\n", "defp g do", "2", :end,
                 source_path: "lib/x.ex",
                 dest_path: "lib/y.ex"
               )

      assert message =~ "does not parse"
      assert message =~ "not a complete unit"
    end

    test "moving a complete function parses and is allowed" do
      source = "defp f do\n  1\nend\n\ndefp g do\n  2\nend\n"

      assert {:ok, _out} =
               Region.move(source, "x\n", "defp g do", "end\n", :end,
                 source_path: "lib/x.ex",
                 dest_path: "lib/y.ex"
               )
    end

    test "a broken destination is named as the destination" do
      # the source stays a complete unit; only the destination (which is
      # missing its own `end`) breaks. The old guard picked the first
      # Elixir path and blamed the source (review N135).
      source = "def f do\n  1\nend\n"
      dest = "def g do\n"

      assert {:error, message} =
               Region.move(source, dest, "def f", "end\n", :end,
                 source_path: "src.ex",
                 dest_path: "dst.ex"
               )

      assert message =~ "(dst.ex)"
      refute message =~ "(src.ex)"
      assert message =~ "missing terminator"
    end

    test "each side is parsed against its own path (.ex -> .html)" do
      # The destination is HTML, not Elixir: parsing it as Elixir would
      # refuse a move that is perfectly valid (review N135).
      source = "def f do\n  1\nend\n"

      assert {:ok, _} =
               Region.move(source, "<html>\n", "def f", "end\n", :end,
                 source_path: "a.ex",
                 dest_path: "b.html"
               )
    end

    test "non-Elixir paths are not parsed" do
      # unbalanced braces are fine in a markdown file
      source = "```\nunclosed\n"

      assert {:ok, _} =
               Region.move(source, "x\n", "unclosed", "unclosed", :end,
                 source_path: "TODO.md",
                 dest_path: "docs/y.md"
               )
    end
  end
end
