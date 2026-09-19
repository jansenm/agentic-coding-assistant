defmodule CodingAgent.Core.Session.PromptTest do
  @moduledoc """
  Unit tests for the extracted prompt composition (P3). The session-level
  integration (agent switch recomposition, memory in the context) stays
  in the session/agent tests; these pin the layers and their order.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Session.Prompt

  setup do
    root = System.tmp_dir!() |> Path.join("prompt-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "base/2 is framework + project memory, in that order", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), "PROJECT-RULE")

    base = Prompt.base(nil, root)

    assert base =~ "coding assistant"
    assert base =~ "PROJECT-RULE"
    # framework first, memory after
    assert :binary.match(base, "coding assistant") |> elem(0) <
             :binary.match(base, "PROJECT-RULE") |> elem(0)
  end

  test "base/2 honors a caller's prompt override", %{root: root} do
    assert Prompt.base("CUSTOM", root) =~ "CUSTOM"
    refute Prompt.base("CUSTOM", root) =~ "coding assistant"
  end

  test "compose_agent/2 appends a non-blank agent prompt" do
    assert Prompt.compose_agent("BASE", "AGENT") == "BASE\n\nAGENT"
  end

  test "compose_agent/2 leaves a blank agent prompt alone" do
    assert Prompt.compose_agent("BASE", "") == "BASE"
    assert Prompt.compose_agent("BASE", "   \n") == "BASE"
  end

  test "replace_in_context/2 replaces the system message in place" do
    context =
      ReqLLM.Context.new()
      |> ReqLLM.Context.append(ReqLLM.Context.system("OLD"))
      |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))

    replaced = Prompt.replace_in_context(context, "NEW")
    [system, user] = ReqLLM.Context.to_list(replaced)

    assert Enum.map_join(system.content, "", &(&1.text || "")) == "NEW"
    assert user.role == :user
  end

  test "replace_in_context/2 prepends a system message when there is none" do
    context = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))
    [system, _user] = ReqLLM.Context.to_list(Prompt.replace_in_context(context, "NEW"))
    assert system.role == :system
  end
end
