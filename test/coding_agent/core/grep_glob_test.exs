defmodule CodingAgent.Core.Tools.GrepGlobTest do
  use ExUnit.Case, async: false

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

    test "absolute-ish patterns never leak outside (relative match only)", %{scope: scope} do
      :file.make_symlink(
        String.to_charlist(System.tmp_dir!()),
        String.to_charlist(Path.join(@root, "outdir"))
      )

      {:ok, out} = ReqLLM.Tool.execute(glob_tool(scope), %{"pattern" => "outdir/**"})
      assert out == "(no matches)"
    end
  end

  describe "grep" do
    test "returns path:line:line-text matches", %{scope: scope} do
      {:ok, out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "needle"})
      assert out =~ "top.txt:1:"
      assert out =~ "needle here"
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

    test "containment: symlinked files and dirs outside the scope are invisible", %{
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

      # direct link read
      {:ok, out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "SECRET-FROM-OUTSIDE"})
      assert String.trim(out) == ""

      # and the walk must not descend through the out-of-scope dir
      {:ok, out2} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "."})
      refute out2 =~ "outdir"
      refute out2 =~ "SECRET"

      # single-file read through the link rejects
      {:error, msg} =
        ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "x", "path" => "leak.txt"})

      assert msg =~ "escapes the session scope"
    end

    test "invalid regex is rejected", %{scope: scope} do
      {:error, msg} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "(", "path" => "."})
      assert msg =~ "invalid regex"
    end

    test "missing target path is rejected", %{scope: scope} do
      {:error, msg} =
        ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "x", "path" => "nope/missing"})

      assert msg =~ "no such file"
    end

    test "results are capped", %{scope: scope} do
      big = Path.join(@root, "big.txt")
      File.write!(big, Enum.map_join(1..600, "\n", &"match-#{&1}"))

      {:ok, out} = ReqLLM.Tool.execute(grep_tool(scope), %{"pattern" => "match-"})
      assert out =~ "capped at #{Tools.Grep.max_results()}"
      File.rm!(big)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp grep_tool(scope), do: scope |> Tools.read_only() |> Enum.find(&(&1.name == "grep"))
  defp glob_tool(scope), do: scope |> Tools.read_only() |> Enum.find(&(&1.name == "glob"))
end
