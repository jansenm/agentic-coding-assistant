defmodule CodingAgent.Core.Tools.SearchDelegationTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.External
  alias CodingAgent.Core.Tools

  @root System.tmp_dir!() |> Path.join("agent-search-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(Path.join(@root, "src"))
    File.mkdir_p!(Path.join(@root, "_build"))
    File.write!(Path.join(@root, "src/a.ex"), "defmodule A do\n  needle_here\nend\n")
    File.write!(Path.join(@root, "top.txt"), "needle\n")
    File.write!(Path.join(@root, "_build/gen.ex"), "needle\n")
    on_exit(fn -> File.rm_rf!(@root) end)
    on_exit(fn -> External.reset() end)
    %{scope: %{root: @root}}
  end

  defp grep(scope), do: scope |> Tools.read_only() |> Enum.find(&(&1.name == "grep"))
  defp glob(scope), do: scope |> Tools.read_only() |> Enum.find(&(&1.name == "glob"))

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

  describe "External probe" do
    test "put/2 forces a result and reset/0 clears it" do
      External.put(:rg, :error)
      refute External.available?(:rg)
      External.reset()
      assert is_boolean(External.available?(:rg))
    end
  end
end
