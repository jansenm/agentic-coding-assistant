defmodule CodingAgent.Core.Tools.FileToolsTest do
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
      refute out =~ ~r/^sub.txt/m
    end

    test "rejects escape attempts", %{scope: scope} do
      tool = find_tool("list_dir", scope)
      {:error, msg} = ReqLLM.Tool.execute(tool, %{"path" => "../../etc"})
      assert msg =~ "escapes"
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

    test "rejects files above 256 KiB", %{scope: scope} do
      tool = find_tool("read_file", scope)
      {:error, msg} = ReqLLM.Tool.execute(tool, %{"path" => "big.bin"})
      assert msg =~ "256 KiB"
    end

    test "rejects directories", %{scope: scope} do
      tool = find_tool("read_file", scope)
      {:error, msg} = ReqLLM.Tool.execute(tool, %{"path" => "nested"})
      assert msg =~ "not a file"
    end

    test "rejects missing files", %{scope: scope} do
      tool = find_tool("read_file", scope)
      {:error, msg} = ReqLLM.Tool.execute(tool, %{"path" => "nope.txt"})
      assert msg =~ "not a file"
    end
  end

  defp find_tool(name, scope) do
    Enum.find(Tools.read_only(scope), &(&1.name == name))
  end
end
