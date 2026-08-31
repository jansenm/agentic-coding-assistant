defmodule CodingAgent.Core.ToolsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Tools

  describe "read_only/1" do
    test "contains only read-only tool names" do
      names = Tools.read_only() |> Enum.map(& &1.name)
      assert names == ["list_dir", "read_file", "grep", "glob"]
    end

    test "tools are valid ReqLLM.Tool structs" do
      for tool <- Tools.read_only() do
        assert %ReqLLM.Tool{} = tool
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_function(tool.callback) or is_tuple(tool.callback)
      end
    end
  end

  describe "in_scope?/2" do
    setup do
      %{scope: %{root: "/tmp/agent-test-root"}}
    end

    test "allows paths inside the root", %{scope: scope} do
      assert Tools.in_scope?(scope, "sub/file.ex")
      assert Tools.in_scope?(scope, ".")
      assert Tools.in_scope?(scope, "/tmp/agent-test-root/sub")
    end

    test "rejects traversal outside the root", %{scope: scope} do
      refute Tools.in_scope?(scope, "../outside")
      refute Tools.in_scope?(scope, "/etc/passwd")
      refute Tools.in_scope?(scope, "sub/../../ ..")
    end
  end
end
