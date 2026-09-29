defmodule CodingAgent.Core.Tools.FileToolsTest do
  @moduledoc """
  The native file tools under ADR 030: each operation runs as a confined
  child process through `Tools.FileExec`, and the session PROFILE is the
  only boundary. The suite's confining double does not actually confine,
  so these tests pin the tool contract (output shapes, fail-closed
  matching, caps); the real read/write/hide semantics are asserted in the
  bwrap integration tests.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Tools

  setup do
    root = Path.join(System.tmp_dir!(), "agent-tools-#{System.unique_integer()}")
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "top.txt"), "top level")
    File.write!(Path.join(root, "nested.txt"), "nested content")
    File.write!(Path.join(root, "big.bin"), String.duplicate("x", 300 * 1024))

    %{scope: %{root: root}}
  end

  describe "list_dir" do
    test "lists the root directory", %{scope: scope} do
      tool = find_tool("list_dir", scope)
      {:ok, out} = ReqLLM.Tool.execute(tool, %{"path" => "."})
      assert out =~ "nested.txt"
    end

    test "marks directories with trailing slash", %{scope: scope} do
      tool = find_tool("list_dir", scope)
      {:ok, out} = ReqLLM.Tool.execute(tool, %{})
      assert out =~ ~r/^sub\/$/m
      assert out =~ ~r/^top\.txt$/m
      refute out =~ ~r/^sub\.txt/m
    end

    test "sorts entries deterministically", %{scope: scope} do
      tool = find_tool("list_dir", scope)
      {:ok, out} = ReqLLM.Tool.execute(tool, %{})
      assert String.split(out, "\n") == Enum.sort(String.split(out, "\n"))
    end

    test "reports missing directories gracefully", %{scope: scope} do
      tool = find_tool("list_dir", scope)
      {:error, msg} = ReqLLM.Tool.execute(tool, %{"path" => "does-not-exist"})
      assert msg =~ "cannot list"
    end
  end

  describe "read_file" do
    test "reads file content", %{scope: scope} do
      tool = find_tool("read_file", scope)
      {:ok, content} = ReqLLM.Tool.execute(tool, %{"path" => "top.txt"})
      assert content == "top level"
    end

    test "reads a file named by an absolute path", %{scope: scope} do
      tool = find_tool("read_file", scope)
      absolute = Path.join(scope.root, "top.txt")
      {:ok, content} = ReqLLM.Tool.execute(tool, %{"path" => absolute})
      assert content == "top level"
    end

    test "rejects files above 256 KiB", %{scope: scope} do
      tool = find_tool("read_file", scope)
      {:error, msg} = ReqLLM.Tool.execute(tool, %{"path" => "big.bin"})
      assert msg =~ "256 KiB"
    end

    test "reports a missing file with the program's message", %{scope: scope} do
      tool = find_tool("read_file", scope)
      {:error, msg} = ReqLLM.Tool.execute(tool, %{"path" => "nope.txt"})
      assert msg =~ "nope.txt"
    end

    test "requires a non-empty path", %{scope: scope} do
      tool = find_tool("read_file", scope)
      assert {:error, msg} = ReqLLM.Tool.execute(tool, %{"path" => ""})
      assert msg =~ "non-empty"
    end

    test "reads a line window with offset and limit (ADR 038)", %{scope: scope} do
      File.write!(Path.join(scope.root, "lines.txt"), Enum.map_join(1..10, "\n", &"L#{&1}"))
      tool = find_tool("read_file", scope)

      {:ok, win} =
        ReqLLM.Tool.execute(tool, %{"path" => "lines.txt", "offset" => 3, "limit" => 2})

      assert win =~ "L3\nL4"
      assert win =~ "lines 3-4 of 10"
      assert win =~ "read on with offset 5"
    end

    test "a window reads a file larger than the whole-file cap", %{scope: scope} do
      # 5000 lines well over 256 KiB; the window must still work
      File.write!(Path.join(scope.root, "huge.log"), Enum.map_join(1..5000, "\n", &"row #{&1}"))

      tool = find_tool("read_file", scope)
      {:ok, win} = ReqLLM.Tool.execute(tool, %{"path" => "huge.log", "offset" => 4999})

      assert win =~ "row 4999"
      assert win =~ "row 5000"
      assert win =~ "lines 4999-5000 of 5000"
    end

    test "offset without a limit uses the default page size", %{scope: scope} do
      File.write!(Path.join(scope.root, "lines.txt"), Enum.map_join(1..300, "\n", &"L#{&1}"))
      tool = find_tool("read_file", scope)

      {:ok, win} = ReqLLM.Tool.execute(tool, %{"path" => "lines.txt", "offset" => 1})
      # default limit is 200
      assert win =~ "lines 1-200 of 300"
    end

    test "rejects a non-positive offset", %{scope: scope} do
      tool = find_tool("read_file", scope)
      assert {:error, msg} = ReqLLM.Tool.execute(tool, %{"path" => "top.txt", "offset" => 0})
      assert msg =~ "positive integer"
    end
  end

  describe "write_file (confined tee)" do
    test "writes content", %{scope: scope} do
      tool = find_tool("write_file", scope)
      {:ok, msg} = ReqLLM.Tool.execute(tool, %{"path" => "new.txt", "content" => "written"})

      assert msg =~ "wrote new.txt"
      assert File.read!(Path.join(scope.root, "new.txt")) == "written"
    end

    test "overwrites an existing file", %{scope: scope} do
      tool = find_tool("write_file", scope)
      {:ok, _} = ReqLLM.Tool.execute(tool, %{"path" => "top.txt", "content" => "replaced"})
      assert File.read!(Path.join(scope.root, "top.txt")) == "replaced"
    end

    test "is byte-exact for multibyte content", %{scope: scope} do
      tool = find_tool("write_file", scope)
      content = String.duplicate("ü✓ line\n", 300)
      {:ok, _} = ReqLLM.Tool.execute(tool, %{"path" => "uni.txt", "content" => content})
      assert File.read!(Path.join(scope.root, "uni.txt")) == content
    end

    test "reports a missing directory rather than raising", %{scope: scope} do
      tool = find_tool("write_file", scope)
      {:error, msg} = ReqLLM.Tool.execute(tool, %{"path" => "no/such/dir.txt", "content" => "x"})
      assert msg =~ "no/such/dir.txt"
    end
  end

  describe "edit (confined read, BEAM replace, confined write)" do
    test "replaces a unique occurrence", %{scope: scope} do
      tool = find_tool("edit", scope)

      {:ok, msg} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "top.txt",
          "old_string" => "top",
          "new_string" => "TOP"
        })

      assert msg =~ "1 replacement"
      assert File.read!(Path.join(scope.root, "top.txt")) == "TOP level"
    end

    test "an ambiguous match refuses (fail closed)", %{scope: scope} do
      File.write!(Path.join(scope.root, "dup.txt"), "x x")
      tool = find_tool("edit", scope)

      {:error, msg} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "dup.txt",
          "old_string" => "x",
          "new_string" => "y"
        })

      assert msg =~ "ambiguous"
      assert File.read!(Path.join(scope.root, "dup.txt")) == "x x"
    end

    test "a stale match refuses and points at re-reading", %{scope: scope} do
      tool = find_tool("edit", scope)

      {:error, msg} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "top.txt",
          "old_string" => "not present",
          "new_string" => "y"
        })

      assert msg =~ "not found"
      assert msg =~ "re-read"
    end

    test "empty old_string creates a missing file", %{scope: scope} do
      tool = find_tool("edit", scope)

      {:ok, _} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "created.txt",
          "old_string" => "",
          "new_string" => "fresh"
        })

      assert File.read!(Path.join(scope.root, "created.txt")) == "fresh"
    end

    test "empty old_string on an existing file refuses", %{scope: scope} do
      tool = find_tool("edit", scope)

      {:error, msg} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "top.txt",
          "old_string" => "",
          "new_string" => "x"
        })

      assert msg =~ "already exists"
    end

    test "a missing file for a real edit refuses", %{scope: scope} do
      tool = find_tool("edit", scope)

      {:error, msg} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "gone.txt",
          "old_string" => "a",
          "new_string" => "b"
        })

      assert msg =~ "no such file"
    end
  end

  defp find_tool(name, scope) do
    Enum.find(Tools.all(scope), &(&1.name == name))
  end
end
