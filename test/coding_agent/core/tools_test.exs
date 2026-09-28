defmodule CodingAgent.Core.ToolsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Tools

  describe "read_only/1" do
    test "contains only read-only tool names" do
      names = Tools.read_only() |> Enum.map(& &1.name)
      # `question` is read-only by nature: the session intercepts the call
      # and the human answers it (ADR 027). `todowrite` is pure session
      # state, also intercepted (ADR 031).
      assert names == ["list_dir", "read_file", "grep", "glob", "question", "todowrite"]
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

  describe "delegation/1 (task, ADR 017/018)" do
    test "a depth-0 scope offers the task tool; a depth-1 scope does not" do
      assert [%{name: "task"}] = Tools.delegation(%{root: ".", depth: 0})
      assert Tools.delegation(%{root: ".", depth: 1}) == []
    end

    test "the default scope (no depth) offers it" do
      assert Enum.map(Tools.delegation(), & &1.name) == ["task"]
    end

    test "the task tool is part of all/1 for a primary" do
      assert "task" in Enum.map(Tools.all(%{root: ".", depth: 0}), & &1.name)
      refute "task" in Enum.map(Tools.all(%{root: ".", depth: 1}), & &1.name)
    end

    test "the description names the available subagents" do
      tool = CodingAgent.Core.Tools.Task.tool(%{root: ".", subagents: ["explore", "review"]})

      assert tool.description =~ "explore"
      assert tool.description =~ "review"
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
