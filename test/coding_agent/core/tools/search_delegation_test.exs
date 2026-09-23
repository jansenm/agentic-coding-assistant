defmodule CodingAgent.Core.Tools.SearchDelegationTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.External
  alias CodingAgent.Core.Tools

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

  # Run the same call twice: once with the external engine as found on
  # this machine, once with it forced off (the reference engine).
  defp both_engines(tool, args, engine) do
    External.reset()
    {:ok, delegated} = ReqLLM.Tool.execute(tool, args)

    External.put(engine, :error)
    {:ok, reference} = ReqLLM.Tool.execute(tool, args)

    External.reset()
    {delegated, reference}
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

    test "does not read through an out-of-scope symlink", %{scope: s} do
      outside = System.tmp_dir!() |> Path.join("sd-secret-#{System.unique_integer()}")
      File.write!(outside, "SECRET-OUTSIDE\n")
      on_exit(fn -> File.rm_rf!(outside) end)

      :file.make_symlink(
        String.to_charlist(outside),
        String.to_charlist(Path.join(@root, "leak.txt"))
      )

      {:ok, out} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "SECRET-OUTSIDE"})
      refute out =~ "SECRET-OUTSIDE"

      {:error, msg} =
        ReqLLM.Tool.execute(grep(s), %{"pattern" => "x", "path" => "leak.txt"})

      assert msg =~ "escapes the session scope"
    end

    test "a pattern rejected by PCRE2 falls back instead of erroring", %{scope: s} do
      # Elixir accepts this; the reference engine matches it too.
      {:ok, out} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "needle|nothing"})
      assert out =~ "needle"
    end
  end

  describe "grep without ripgrep (forced fallback)" do
    setup do
      External.put(:rg, :error)
      :ok
    end

    test "the pure-Elixir path still answers", %{scope: s} do
      {:ok, out} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "needle"})
      assert out =~ "top.txt:1:"
      refute out =~ "_build"
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

  describe "glob without fd (forced fallback)" do
    setup do
      External.put(:fd, :error)
      :ok
    end

    test "the pure-Elixir path still answers", %{scope: s} do
      {:ok, out} = ReqLLM.Tool.execute(glob(s), %{"pattern" => "**/*.ex"})
      assert out =~ "src/a.ex"
      refute out =~ "_build"
    end
  end

  # The test that was missing. fd matched the entry NAME (so `lib/**/*.ex`
  # found nothing), read `[...]`/`!` its own way, answered smart-case, and
  # returned hidden entries; rg's `--glob` is a third dialect again. Both
  # tools must answer one thing, whatever engine is installed (measured:
  # 2 of 8 glob shapes and 3 of 9 grep shapes diverged before this).
  describe "engine agreement (delegated == reference, for every documented shape)" do
    test "glob", %{scope: s} do
      for pattern <- @glob_shapes do
        {delegated, reference} = both_engines(glob(s), %{"pattern" => pattern}, :fd)
        assert delegated == reference, "glob #{inspect(pattern)}: #{delegated} != #{reference}"
      end
    end

    test "grep, including the glob argument", %{scope: s} do
      calls = [
        %{"pattern" => "needle"},
        %{"pattern" => "needle", "glob" => "*.ex"},
        %{"pattern" => "needle", "glob" => "**/*.ex"},
        %{"pattern" => "needle", "glob" => "lib/**/*.ex"},
        %{"pattern" => "needle", "glob" => "src/*.ex"},
        %{"pattern" => "needle", "glob" => "*.txt"},
        %{"pattern" => "needle", "glob" => ".hidden.ex"},
        %{"pattern" => "needle", "glob" => ".github/**/*.yml"},
        %{"pattern" => "needle", "glob" => "*.yml"},
        %{"pattern" => "needle", "path" => "lib"},
        %{"pattern" => "needle", "path" => "lib/.private"},
        %{"pattern" => "needle", "path" => ".github"},
        %{"pattern" => "needle", "path" => "src/doc"}
      ]

      for args <- calls do
        {delegated, reference} = both_engines(grep(s), args, :rg)
        assert delegated == reference, "grep #{inspect(args)}: #{delegated} != #{reference}"
      end
    end
  end

  describe "hidden entries: a default, and the opt-in is naming them" do
    test "a plain search returns no hidden entry, in either engine", %{scope: s} do
      {delegated, reference} = both_engines(glob(s), %{"pattern" => "**/*"}, :fd)

      for out <- [delegated, reference] do
        refute out =~ ".hidden.ex"
        refute out =~ ".env.example"
        refute out =~ ".github"
        assert out =~ "top.txt"
      end
    end

    test "the leak guard: --hidden must not widen a pattern that did not ask", %{scope: s} do
      # fd is invoked with --hidden (an opting-in pattern needs it); the
      # filter is what keeps every OTHER pattern at its old result set.
      for pattern <- ["**/*", "*.ex", "**/*.ex", "**/*.yml", "*.pem", "**/*.txt"],
          engine <- [:fd] do
        {delegated, reference} = both_engines(glob(s), %{"pattern" => pattern}, engine)

        assert delegated == reference, "#{inspect(pattern)}: #{delegated} != #{reference}"

        refute delegated =~ ".hidden.ex"
        refute delegated =~ ".env.example"
      end
    end

    test "a pattern that NAMES a hidden entry finds it, in both engines", %{scope: s} do
      for pattern <- [".hidden.ex", ".*", "**/.hidden.ex", ".github/**/*.yml"] do
        {delegated, reference} = both_engines(glob(s), %{"pattern" => pattern}, :fd)

        assert delegated == reference
        assert delegated != "(no matches)", "#{inspect(pattern)} found nothing"
      end

      {delegated, reference} = both_engines(glob(s), %{"pattern" => ".hidden.ex"}, :fd)
      assert delegated =~ ".hidden.ex"
      assert delegated == reference
    end

    test "grep: naming the hidden file (glob or path) is the opt-in too", %{scope: s} do
      named = [
        %{"pattern" => "needle", "glob" => ".hidden.ex"},
        %{"pattern" => "needle", "glob" => ".github/**/*.yml"},
        %{"pattern" => "needle", "path" => ".github"},
        %{"pattern" => "needle", "path" => "lib/.private"}
      ]

      for args <- named do
        {delegated, reference} = both_engines(grep(s), args, :rg)
        assert delegated == reference, "#{inspect(args)}: #{delegated} != #{reference}"
        assert delegated =~ "needle"
      end

      # ... and a NON-naming filter still cannot reach one
      {:ok, out} = ReqLLM.Tool.execute(grep(s), %{"pattern" => "needle", "glob" => "*.ex"})
      refute out =~ ".hidden.ex"
      refute out =~ ".private"
    end

    test "the walk's opt-in reaches a hidden entry named by a dir pattern", %{scope: s} do
      # `**/.private/**` names a hidden segment, so the walk descends into
      # it; `**/*.ex` does not, so it does not. One rule, both engines.
      {delegated, reference} = both_engines(glob(s), %{"pattern" => "**/.private/**"}, :fd)
      assert delegated == reference
      assert delegated =~ "lib/.private/p.ex"

      {:ok, out} = ReqLLM.Tool.execute(glob(s), %{"pattern" => "lib/**/*.ex"})
      refute out =~ ".private"
    end
  end

  describe "build/vendor trees are pruned by both engines, at any depth" do
    test "glob", %{scope: s} do
      for pattern <- ["**/*.ex", "**/*", "*.txt", "**/*.txt", "src/**/*"] do
        {delegated, reference} = both_engines(glob(s), %{"pattern" => pattern}, :fd)

        assert delegated == reference, "#{inspect(pattern)}: #{delegated} != #{reference}"
        refute delegated =~ "_build"
        refute delegated =~ "src/doc"
      end
    end

    test "grep", %{scope: s} do
      for args <- [
            %{"pattern" => "needle"},
            %{"pattern" => "needle", "glob" => "*.txt"},
            %{"pattern" => "needle", "path" => "src"}
          ] do
        {delegated, reference} = both_engines(grep(s), args, :rg)
        assert delegated == reference, "#{inspect(args)}: #{delegated} != #{reference}"
        refute delegated =~ "_build"
        refute delegated =~ "src/doc"
      end
    end
  end

  describe "the delegated invocation itself (guard against regressions in the flags)" do
    # These tests are about fd/rg, so they need the binaries on this
    # machine. Without them the reference engine answers (covered above)
    # and there is nothing to pin here.
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

  describe "External probe" do
    test "put/2 forces a result and reset/0 clears it" do
      External.put(:rg, :error)
      refute External.available?(:rg)
      External.reset()
      assert is_boolean(External.available?(:rg))
    end
  end
end
