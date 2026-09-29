defmodule CodingAgent.Core.Tools.SearchDelegationTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.External
  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.FdSearch

  @root System.tmp_dir!() |> Path.join("agent-search-#{System.unique_integer([:positive])}")

  # Documented glob shapes, one list for both tools: every one of these
  # must answer IDENTICALLY with and without the external engine (the
  # "engine agreement" tests below). Patterns fd's dialect would read
  # differently are in there on purpose — they are the fallback's job.
  @glob_shapes [
    "**/*.ex",
    "lib/**/*.ex",
    "lib/*.ex",
    "src/*.ex",
    "*.txt",
    "**/*",
    "*.{ex,txt}",
    "**/*.{ex,exs}",
    "?.ex",
    "**/*.EX",
    "*.env.example",
    ".hidden.ex",
    ".*",
    "**/.*",
    ".github/**/*.yml",
    "**/*.yml",
    "lib/.private/*.ex",
    "**/.private/**",
    "*.pem",
    # fd divergences -> the reference engine must answer these
    "[ab].ex",
    "!bang.ex",
    "weird.[ex]s",
    "lib/./*.ex",
    "**/",
    "/lib/*.ex"
  ]

  setup do
    File.rm_rf!(@root)

    for dir <- [
          "src",
          "_build/prod",
          "lib/nested",
          "lib/.private",
          ".github/workflows",
          "src/doc"
        ] do
      File.mkdir_p!(Path.join(@root, dir))
    end

    File.write!(Path.join(@root, "src/a.ex"), "defmodule A do\n  needle_here\nend\n")
    File.write!(Path.join(@root, "top.txt"), "needle\n")
    File.write!(Path.join(@root, "_build/gen.ex"), "needle\n")
    File.write!(Path.join(@root, "src/doc/manual.txt"), "needle\n")
    File.write!(Path.join(@root, "lib/nested/b.ex"), "needle\n")
    File.write!(Path.join(@root, "lib/.private/p.ex"), "needle\n")
    File.write!(Path.join(@root, ".github/workflows/ci.yml"), "needle\n")
    File.write!(Path.join(@root, ".hidden.ex"), "needle\n")
    File.write!(Path.join(@root, ".env.example"), "needle\n")
    File.write!(Path.join(@root, "weird.[ex]s"), "needle\n")
    File.write!(Path.join(@root, "!bang.ex"), "needle\n")
    # a FILE named like a skip dir: fd's --exclude prunes it, the walk's
    # skip list must too (otherwise the two engines disagree again)
    File.write!(Path.join(@root, "cover"), "needle\n")
    File.write!(Path.join(@root, "src/cover"), "needle\n")

    on_exit(fn -> File.rm_rf!(@root) end)
    on_exit(fn -> External.reset() end)
    %{scope: %{root: @root}}
  end

  defp grep(scope), do: scope |> Tools.read_only() |> Enum.find(&(&1.name == "grep"))
  defp glob(scope), do: scope |> Tools.read_only() |> Enum.find(&(&1.name == "glob"))

  # ADR 030: there is no second engine. The ORACLE for a shape is the
  # reference filter applied to the tree by the test itself; the tool's
  # answer (fd/rg + the same filter) must equal it. `tool_answer/2` runs
  # the real tool with the engine available; the oracle helpers below
  # compute the expected set.
  defp tool_answer(tool, args) do
    External.reset()
    {:ok, out} = ReqLLM.Tool.execute(tool, args)
    out
  end

  defp all_files(root) do
    Path.wildcard(Path.join(root, "**"), match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(&skip_tree?/1)
  end

  # only DIRECTORY components are pruned (a FILE named like a skip dir is
  # yielded by the reference walk); check each prefix against the fs.
  defp skip_tree?(rel) do
    rel
    |> Path.split()
    |> Enum.reduce_while("", fn segment, acc ->
      path = Path.join(acc, segment)

      if path != rel and File.dir?(Path.join(@root, path)) and
           segment in ~w(_build deps .git doc cover .elixir_ls) do
        {:halt, true}
      else
        {:cont, path}
      end
    end)
    |> Kernel.==(true)
  end

  defp glob_oracle(root, pattern) do
    all_files(root)
    |> Enum.filter(&CodingAgent.Core.Tools.Glob.file_match?(pattern, &1, Path.basename(&1)))
    |> CodingAgent.Core.Containment.filter_hidden([pattern])
    |> Enum.sort()
    |> Enum.take(CodingAgent.Core.Tools.Glob.max_results())
    |> Enum.join("\n")
  end

  describe "grep contract (engine-agnostic; rg is used when present)" do
    test "returns path:line:text", %{scope: s} do
      {:ok, out} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "needle"})
      assert out =~ "top.txt:1:"
      assert out =~ "src/a.ex:2:"
    end

    test "skips _build (shared skip list)", %{scope: s} do
      {:ok, out} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "needle"})
      refute out =~ "_build"
    end

    test "glob param filters files", %{scope: s} do
      {:ok, out} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "needle", "glob" => "*.ex"})
      assert out =~ "src/a.ex"
      refute out =~ "top.txt"
    end

    test "restricting the path to a subdir works", %{scope: s} do
      {:ok, out} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "needle", "path" => "src"})
      assert out =~ "src/a.ex"
      refute out =~ "top.txt"
    end

    test "does not read through an out-of-scope symlink (filter)", %{scope: s} do
      outside = System.tmp_dir!() |> Path.join("sd-secret-#{System.unique_integer()}")
      File.write!(outside, "SECRET-OUTSIDE\n")
      on_exit(fn -> File.rm_rf!(outside) end)

      :file.make_symlink(
        String.to_charlist(outside),
        String.to_charlist(Path.join(@root, "leak.txt"))
      )

      # ADR 030: rg may read the symlinked target (the profile decides
      # reach), but every returned path is re-checked PHYSICALLY against
      # the scope — the leak cannot be REPORTED. Both the walk and the
      # explicit-file shape are covered.
      {:ok, out} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "SECRET-OUTSIDE"})
      refute out =~ "SECRET-OUTSIDE"

      {:ok, out2} =
        ReqLLM.Tool.execute(grep(s), %{"pattern" => "SECRET-OUTSIDE", "path" => "leak.txt"})

      refute out2 =~ "SECRET-OUTSIDE"
    end

    test "a pattern rejected by PCRE2 falls back instead of erroring", %{scope: s} do
      # Elixir accepts this; the reference engine matches it too.
      {:ok, out} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "needle|nothing"})
      assert out =~ "needle"
    end
  end

  describe "grep without ripgrep (ADR 030: required)" do
    setup do
      External.put(:rg, :error)
      :ok
    end

    test "refuses with a clear message instead of an unconfined fallback", %{scope: s} do
      {:error, msg} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "needle"})
      assert msg =~ "ripgrep"
      assert msg =~ "required"
    end
  end

  describe "glob contract (engine-agnostic; fd is used when present)" do
    test "finds files and skips _build", %{scope: s} do
      {:ok, out} = ReqLLM.Tool.execute(glob(s), %{"pattern" => "**/*.ex"})
      assert out =~ "src/a.ex"
      refute out =~ "_build"
    end

    test "brace expansion", %{scope: s} do
      {:ok, out} = ReqLLM.Tool.execute(glob(s), %{"pattern" => "**/*.{ex,txt}"})
      assert out =~ "src/a.ex"
      assert out =~ "top.txt"
    end

    test "out-of-scope symlinks are not listed", %{scope: s} do
      outside = System.tmp_dir!() |> Path.join("sd-l-#{System.unique_integer()}")
      File.write!(outside, "x")
      on_exit(fn -> File.rm_rf!(outside) end)

      :file.make_symlink(
        String.to_charlist(outside),
        String.to_charlist(Path.join(@root, "leak.txt"))
      )

      {:ok, out} = ReqLLM.Tool.execute(glob(s), %{"pattern" => "**/*"})
      refute out =~ "leak.txt"
    end
  end

  describe "glob without fd (ADR 030: required)" do
    setup do
      External.put(:fd, :error)
      :ok
    end

    test "refuses with a clear message instead of an unconfined fallback", %{scope: s} do
      {:error, msg} = ReqLLM.Tool.execute(glob(s), %{"pattern" => "**/*.ex"})
      assert msg =~ "fd"
      assert msg =~ "required"
    end
  end

  # The test that was missing. fd matched the entry NAME (so `lib/**/*.ex`
  # found nothing), read `[...]`/`!` its own way, answered smart-case, and
  # returned hidden entries; rg's `--glob` is a third dialect again. Both
  # tools must answer one thing, whatever engine is installed (measured:
  # 2 of 8 glob shapes and 3 of 9 grep shapes diverged before this).
  describe "the documented shape answers match the reference rule (ADR 030)" do
    test "glob", %{scope: s} do
      for pattern <- @glob_shapes do
        expected =
          case glob_oracle(@root, pattern) do
            "" -> "(no matches)"
            body -> body
          end

        # capped output carries a suffix; compare the body only
        actual = tool_answer(glob(s), %{"pattern" => pattern})

        assert String.starts_with?(actual, expected),
               "glob #{inspect(pattern)}: #{actual} != #{expected}"
      end
    end

    test "grep with a glob filter equals the reference filter over the tree", %{scope: s} do
      # the oracle: every file the reference glob rule accepts, searched
      # for the literal; the tool must return exactly those matches.
      for glob <- [
            "*.ex",
            "**/*.ex",
            "lib/**/*.ex",
            "src/*.ex",
            "*.txt",
            ".hidden.ex",
            ".github/**/*.yml",
            "*.yml"
          ] do
        accepted =
          all_files(@root)
          |> Enum.filter(&CodingAgent.Core.Tools.Glob.file_match?(glob, &1, Path.basename(&1)))
          |> CodingAgent.Core.Containment.filter_hidden([glob, "."])
          |> Enum.sort()

        actual = tool_answer(grep(s), %{"pattern" => "needle", "glob" => glob})

        for file <- accepted do
          assert actual =~ file, "grep glob #{inspect(glob)} missed #{file}"
        end

        for file <- all_files(@root), file not in accepted do
          refute actual =~ file, "grep glob #{inspect(glob)} leaked #{file}"
        end
      end
    end

    test "grep with a path target stays inside it", %{scope: s} do
      for {path, expect, reject} <- [
            {"lib", "lib/nested/b.ex", "top.txt"},
            {"lib/.private", "lib/.private/p.ex", "top.txt"},
            {".github", ".github/workflows/ci.yml", "top.txt"},
            {"src/doc", "src/doc/manual.txt", "top.txt"}
          ] do
        actual = tool_answer(grep(s), %{"pattern" => "needle", "path" => path})
        assert actual =~ expect, "grep path #{inspect(path)} missed #{expect}"
        refute actual =~ reject, "grep path #{inspect(path)} leaked #{reject}"
      end
    end
  end

  describe "hidden entries: a default, and the opt-in is naming them" do
    test "a plain search returns no hidden entry", %{scope: s} do
      out = tool_answer(glob(s), %{"pattern" => "**/*"})

      refute out =~ ".hidden.ex"
      refute out =~ ".env.example"
      refute out =~ ".github"
      assert out =~ "top.txt"
    end

    test "the leak guard: --hidden must not widen a pattern that did not ask", %{scope: s} do
      # fd is invoked with --hidden (an opting-in pattern needs it); the
      # filter is what keeps every OTHER pattern at its old result set.
      for pattern <- ["**/*", "*.ex", "**/*.ex", "**/*.yml", "*.pem", "**/*.txt"] do
        out = tool_answer(glob(s), %{"pattern" => pattern})

        refute out =~ ".hidden.ex"
        refute out =~ ".env.example"
      end
    end

    test "a pattern that NAMES a hidden entry finds it", %{scope: s} do
      for pattern <- [".hidden.ex", ".*", "**/.hidden.ex", ".github/**/*.yml"] do
        out = tool_answer(glob(s), %{"pattern" => pattern})
        assert out != "(no matches)", "#{inspect(pattern)} found nothing"
      end

      assert tool_answer(glob(s), %{"pattern" => ".hidden.ex"}) =~ ".hidden.ex"
    end

    test "grep: naming the hidden file (glob or path) is the opt-in too", %{scope: s} do
      named = [
        %{"pattern" => "needle", "glob" => ".hidden.ex"},
        %{"pattern" => "needle", "glob" => ".github/**/*.yml"},
        %{"pattern" => "needle", "path" => ".github"},
        %{"pattern" => "needle", "path" => "lib/.private"}
      ]

      for args <- named do
        out = tool_answer(grep(s), args)
        assert out =~ "needle", "#{inspect(args)}: #{out}"
      end

      # ... and a NON-naming filter still cannot reach one
      {:ok, out} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "needle", "glob" => "*.ex"})
      refute out =~ ".hidden.ex"
      refute out =~ ".private"
    end

    test "a hidden entry named by a dir pattern is reachable", %{scope: s} do
      # `**/.private/**` names a hidden segment; `**/*.ex` does not.
      out = tool_answer(glob(s), %{"pattern" => "**/.private/**"})
      assert out =~ "lib/.private/p.ex"

      {:ok, out2} = ReqLLM.Tool.execute(glob(s), %{"pattern" => "lib/**/*.ex"})
      refute out2 =~ ".private"
    end
  end

  describe "build/vendor trees are pruned at any depth" do
    test "glob", %{scope: s} do
      for pattern <- ["**/*.ex", "**/*", "*.txt", "**/*.txt", "src/**/*"] do
        out = tool_answer(glob(s), %{"pattern" => pattern})

        refute out =~ "_build"
        refute out =~ "src/doc"
      end
    end

    test "grep", %{scope: s} do
      for args <- [
            %{"pattern" => "needle"},
            %{"pattern" => "needle", "glob" => "*.txt"},
            %{"pattern" => "needle", "path" => "src"}
          ] do
        out = tool_answer(grep(s), args)

        refute out =~ "_build"
        refute out =~ "src/doc"
      end
    end
  end

  describe "the delegated invocation itself (guard against regressions in the flags)" do
    # These tests are about the delegated invocation, so they need the
    # binaries on this machine. Since ADR 030 rg/fd are required and
    # there is no reference engine to fall back to; without the binaries
    # the tool returns a clear error (covered elsewhere).
    setup do
      %{delegated?: External.available?(:fd) and External.available?(:rg)}
    end

    test "fd answers a rooted pattern (--absolute-path --full-path)", ctx do
      if ctx.delegated? do
        External.reset()
        {:ok, out} = ReqLLM.Tool.execute(glob(ctx.scope), %{"pattern" => "lib/**/*.ex"})
        assert out == "lib/nested/b.ex"
      else
        :ok
      end
    end

    test "fd is case-sensitive like the reference engine", ctx do
      if ctx.delegated? do
        File.write!(Path.join(@root, "UPPER.EX"), "x\n")
        External.reset()
        {:ok, out} = ReqLLM.Tool.execute(glob(ctx.scope), %{"pattern" => "*.EX"})
        assert out == "UPPER.EX"
        File.rm!(Path.join(@root, "UPPER.EX"))
      else
        :ok
      end
    end

    test "an fd parse error is not shown to the model as a result", ctx do
      if ctx.delegated? do
        External.reset()
        {:ok, out} = ReqLLM.Tool.execute(glob(ctx.scope), %{"pattern" => "**/[a-"})
        refute out =~ "fd error"
        assert out == "(no matches)"
      else
        :ok
      end
    end
  end

  describe "FdSearch.parse_paths (review F2/F5): prose is never a path" do
    test "the Exec truncation banner is dropped, not parsed as a file" do
      out =
        "./lib/a.ex\n\n[... output truncated: 300000 bytes total; showing first 131072 and last 131072 ...]\n\n./top.txt\n"

      assert FdSearch.parse_paths(out, @root) == ["lib/a.ex", "top.txt"]
    end

    test "fd diagnostics are dropped" do
      out = "[fd error]: Search path 'nope' is not a directory.\n./top.txt\n"
      assert FdSearch.parse_paths(out, @root) == ["top.txt"]
    end

    test "a bracketed FILENAME is kept (the banner rule is exact, not 'bracketed')" do
      File.write!(Path.join(@root, "[a]needle.ex"), "x\n")
      on_exit(fn -> File.rm(Path.join(@root, "[a]needle.ex")) end)
      assert FdSearch.parse_paths("./[a]needle.ex\n", @root) == ["[a]needle.ex"]
    end

    test "`./`-prefixed output is normalized (the trim is intentional)" do
      assert FdSearch.parse_paths("./src/a.ex\n./.hidden.ex\n", @root) ==
               [".hidden.ex", "src/a.ex"]
    end
  end

  describe "grep caps spill the full list (ADR 038)" do
    test "more matches than the cap spill the full list and name the path", %{scope: s} do
      # 250 matching lines > the 200 cap; a scratch-bearing scope enables
      # the spill (nil otherwise -> plain cap note, covered elsewhere).
      File.write!(Path.join(@root, "many.txt"), Enum.map_join(1..250, "\n", &"needle line #{&1}"))

      scratch = CodingAgent.Core.Session.Scratch.path("grep-spill-#{System.unique_integer()}")
      File.mkdir_p!(scratch)
      on_exit(fn -> File.rm_rf!(scratch) end)

      scope = Map.put(s, :session_id, Path.basename(scratch))

      {:ok, out} =
        ReqLLM.Tool.execute(grep(scope), %{"pattern" => "needle", "glob" => "many.txt"})

      assert out =~ "capped at 200"
      assert out =~ "full list at /tmp/spill/grep-"

      host = Path.wildcard(Path.join(scratch, "spill/grep-*")) |> List.first()
      assert host != nil
      assert File.read!(host) =~ "needle line 250"
    end
  end

  describe "External probe" do
    test "put/2 forces a result and reset/0 clears it" do
      External.put(:rg, :error)
      refute External.available?(:rg)
      External.reset()
      assert is_boolean(External.available?(:rg))
    end
  end
end
