# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.GrepGlobTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Tools

  @root System.tmp_dir!() |> Path.join("agent-grepglob-#{System.unique_integer()}")

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(Path.join(@root, "src"))
    File.write!(Path.join(@root, "src/a.ex"), "defmodule A do\n  :ok\nend\nsecret_here\n")
    File.write!(Path.join(@root, "b.exs"), "defmodule B\n")
    File.write!(Path.join(@root, "src/bin.bin"), <<0, 1, 2, "text">>)
    File.write!(Path.join(@root, "top.txt"), "needle here\n")

    # attacker file outside the scope, linked in
    outside = System.tmp_dir!() |> Path.join("gg-secret-#{System.unique_integer()}")
    File.write!(outside, "SECRET-FROM-OUTSIDE\n")

    on_exit(fn ->
      File.rm_rf!(@root)
      File.rm_rf!(outside)
    end)

    scope = %{root: @root}
    [grep, glob] = Enum.filter(Tools.read_only(scope), &(&1.name in ["grep", "glob"]))

    %{grep: grep, glob: glob, outside: outside, scope: scope}
  end

  describe "glob" do
    test "finds files by pattern", %{scope: scope} do
      {:ok, out} = ReqLLM.Tool.execute(glob_tool(scope), %{"pattern" => "**/*.ex"})
      assert out =~ "src/a.ex"
      refute out =~ "b.exs"
    end

    test "matches top-level files with leading **", %{scope: scope} do
      {:ok, out} = ReqLLM.Tool.execute(glob_tool(scope), %{"pattern" => "**/*"})
      assert out =~ "top.txt"
      assert out =~ "b.exs"
    end

    test "brace expansion", %{scope: scope} do
      {:ok, out} = ReqLLM.Tool.execute(glob_tool(scope), %{"pattern" => "**/*.{ex,exs}"})
      assert out =~ "src/a.ex"
      assert out =~ "b.exs"
    end

    test "skips hidden and build dirs, and out-of-scope symlinks", %{
      scope: scope,
      outside: outside
    } do
      # link pointing outside must be silently skipped, not listed
      :file.make_symlink(
        String.to_charlist(outside),
        String.to_charlist(Path.join(@root, "leak.txt"))
      )

      File.mkdir_p!(Path.join(@root, "_build/prod"))

      {:ok, out} = ReqLLM.Tool.execute(glob_tool(scope), %{"pattern" => "**/*"})
      refute out =~ "leak.txt"
      refute out =~ "_build"
      refute out =~ Path.basename(outside)
    end

    test "out-of-scope symlink targets are never listed", %{scope: scope} do
      :file.make_symlink(
        String.to_charlist(System.tmp_dir!()),
        String.to_charlist(Path.join(@root, "outdir"))
      )

      {:ok, out} = ReqLLM.Tool.execute(glob_tool(scope), %{"pattern" => "outdir/**"})
      # fd may ENUMERATE through the link; the physical re-check drops
      # every path that resolves outside the scope, so nothing leaks.
      refute out =~ "outdir/"
      refute out =~ Path.basename(System.tmp_dir!())
    end
  end

  describe "grep" do
    test "returns path:line:line-text matches", %{scope: scope} do
      {:ok, out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "needle"})
      assert out =~ "top.txt:1:"
      assert out =~ "needle here"
    end

    test "parses a path containing a colon (the --null boundary)", %{scope: scope} do
      File.write!(Path.join(@root, "we:ird.txt"), "needle colon\n")

      {:ok, out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "colon"})
      assert out =~ "we:ird.txt:1:needle colon"
    end

    test "finds matches when path names a single file (review N2)", %{scope: scope} do
      # rg omits the filename for a single named target unless -H; then the
      # path\0line boundary is gone and the parser dropped every match.
      {:ok, out} =
        ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "needle", "path" => "top.txt"})

      assert out =~ "top.txt:1:needle here"
    end

    test "finds matches in a single file reached through a subdirectory", %{scope: scope} do
      File.mkdir_p!(Path.join(@root, "sub"))
      File.write!(Path.join(@root, "sub/b.txt"), "needle there\n")

      {:ok, out} =
        ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "needle", "path" => "sub/b.txt"})

      assert out =~ "sub/b.txt:1:needle there"
    end

    test "skips files over 1 MiB in a directory walk, but a named file is searched (review N3)",
         %{scope: scope} do
      # >1MiB so rg's --max-filesize skips it during traversal
      big = Path.join(@root, "big.log")
      File.write!(big, String.duplicate("filler line here\n", 80_000) <> "needle big\n")

      # directory walk: skipped by the size cap, and NAMED in the answer (a
      # silent skip reads as "no match" — the live finding)
      {:ok, dir_out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "needle"})
      refute dir_out =~ "big.log:"
      assert dir_out =~ "skipped: 1 file(s) over 1 MiB"
      assert dir_out =~ "big.log"

      # explicitly named: rg applies --max-filesize only to traversal
      {:ok, named} =
        ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "needle", "path" => "big.log"})

      assert named =~ "big.log:"
      assert named =~ "needle big"
      File.rm!(big)
    end

    test "does not truncate a match whose line text contains a colon", %{scope: scope} do
      File.write!(Path.join(@root, "cfg.txt"), "key: value: needle:x\n")

      {:ok, out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "needle"})
      assert out =~ "cfg.txt:1:key: value: needle:x"
    end

    test "alternation and glob filters", %{scope: scope} do
      {:ok, out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "needle|secret_here"})
      assert out =~ "top.txt:1:needle"
      assert out =~ "src/a.ex:4:secret_here"

      {:ok, out2} =
        ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "defmodule", "glob" => "*.ex"})

      # only src/a.ex is a *.ex (b.exs filtered out)
      assert out2 =~ "src/a.ex:1:"
      refute out2 =~ "b.exs"
    end

    test "skips binary files", %{scope: scope} do
      File.write!(Path.join(@root, "src/z.bin"), <<0, 0, 1, 2>>)

      {:ok, out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "."})
      refute out =~ "z.bin"
    end

    test "out-of-scope symlinks are never REPORTED (ADR 030 physical re-check)", %{
      scope: scope,
      outside: outside
    } do
      :file.make_symlink(
        String.to_charlist(outside),
        String.to_charlist(Path.join(@root, "leak.txt"))
      )

      :file.make_symlink(
        String.to_charlist(System.tmp_dir!()),
        String.to_charlist(Path.join(@root, "outdir"))
      )

      # the profile may let rg READ the target; every returned path is
      # re-checked physically, so the leak cannot appear in a result
      {:ok, out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "SECRET-FROM-OUTSIDE"})
      refute out =~ "SECRET"

      {:ok, out2} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "."})
      refute out2 =~ "outdir"
      refute out2 =~ "SECRET"

      {:ok, out3} =
        ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "x", "path" => "leak.txt"})

      refute out3 =~ "SECRET"
    end

    test "invalid regex is rejected", %{scope: scope} do
      {:error, msg} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "(", "path" => "."})
      assert msg =~ "invalid regex"
    end

    test "missing target path is reported (rg's own diagnostic)", %{scope: scope} do
      {:error, msg} =
        ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "x", "path" => "nope/missing"})

      assert msg =~ "nope/missing"
    end

    test "results are capped", %{scope: scope} do
      big = Path.join(@root, "big.txt")
      File.write!(big, Enum.map_join(1..600, "\n", &"match-#{&1}"))

      {:ok, out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "match-"})
      assert out =~ "capped at #{Tools.Grep.max_results()}"
      File.rm!(big)
    end

    test "the cap counts ALL matches, not just an Exec-truncated fragment (review F1)", %{
      scope: scope
    } do
      # Enough matches that rg's output far exceeds Exec's 256 KiB cut:
      # before the fix grep saw only the fragment, so the total was wrong
      # and the "full list" spill held the same fragment.
      big = Path.join(@root, "many.txt")
      lines = for i <- 1..4_000, do: "match-#{i}-#{String.duplicate("x", 120)}"
      File.write!(big, Enum.join(lines, "\n"))

      {:ok, out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "match-"})

      # the true total, not the pre-truncation fragment count
      assert out =~ "capped at #{Tools.Grep.max_results()} of 4000 matches"
      File.rm!(big)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp grep_tool(scope), do: scope |> Tools.read_only() |> Enum.find(&(&1.name == "grep"))
  defp glob_tool(scope), do: scope |> Tools.read_only() |> Enum.find(&(&1.name == "glob"))
end
