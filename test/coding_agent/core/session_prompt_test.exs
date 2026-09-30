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

  # -- ADR 024: per-model framework prompt --------------------------------

  describe "family/1" do
    test "maps model ids to a prompt family, defaulting unknown ones" do
      assert Prompt.family("anthropic:claude-sonnet-4-20250514") == "claude"
      assert Prompt.family("github_copilot:claude-3-5") == "claude"
      assert Prompt.family("ollama:qwen3:14b") == "default"
      assert Prompt.family("ollama_cloud:deepseek-v4.1-flash") == "default"
      assert Prompt.family(nil) == "default"
    end
  end

  describe "framework/1" do
    test "returns a real prompt, not the five-line stub, per family" do
      default = Prompt.framework("ollama:qwen3")
      claude = Prompt.framework("anthropic:claude-sonnet-4")

      assert String.length(default) > 500
      assert default != claude
    end

    test "the vendored text never impersonates opencode and names OUR tools" do
      for model <- ["ollama:qwen3", "anthropic:claude-sonnet-4"] do
        prompt = Prompt.framework(model)

        # identity is rewritten (THIRD_PARTY.md): no upstream branding
        refute prompt =~ "opencode"
        refute prompt =~ "OpenCode"
        # our canonical tool names, not opencode's (read/bash/write/...)
        assert prompt =~ "read_file"
        assert prompt =~ "write_file"
      end
    end

    test "an unknown family falls back to the default file" do
      assert Prompt.framework("ollama:qwen3") == Prompt.framework(nil)
    end
  end

  describe "base/3" do
    test "selects the framework prompt by model", %{root: root} do
      assert Prompt.base(nil, root, "anthropic:claude-sonnet-4") =~ "Professional objectivity"
      refute Prompt.base(nil, root, "ollama:qwen3") =~ "Professional objectivity"
    end

    test "an override still wins over the model file", %{root: root} do
      base = Prompt.base("CUSTOM", root, "anthropic:claude-sonnet-4")
      assert base =~ "CUSTOM"
      refute base =~ "Professional objectivity"
    end

    test "project memory is still appended for every model", %{root: root} do
      File.write!(Path.join(root, "AGENTS.md"), "PROJECT-RULE")
      assert Prompt.base(nil, root, "anthropic:claude-sonnet-4") =~ "PROJECT-RULE"
      assert Prompt.base(nil, root, "ollama:qwen3") =~ "PROJECT-RULE"
    end
  end

  # -- ADR 024: the per-call environment block ----------------------------

  describe "environment/2" do
    test "carries the model, cwd, git-repo flag, platform and date", %{root: root} do
      block = Prompt.environment("ollama:test", root)

      assert block =~ "<env>"
      assert block =~ "Model: ollama:test"
      assert block =~ "Working directory: #{root}"
      assert block =~ "Is directory a git repo: no"
      assert block =~ "Platform: "
      assert block =~ "Today's date: #{Date.utc_today()}"
    end

    test "reports a git repo when .git is present", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git"))
      assert Prompt.environment("m", root) =~ "Is directory a git repo: yes"
    end
  end

  describe "with_environment/3" do
    test "appends the block to the system message, leaving the stored context alone" do
      context =
        ReqLLM.Context.new()
        |> ReqLLM.Context.append(ReqLLM.Context.system("BASE"))
        |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))

      on_wire = Prompt.with_environment(context, "ollama:test", "/tmp")

      [%ReqLLM.Message{role: :system} = sys | _] = ReqLLM.Context.to_list(on_wire)
      text = Enum.map_join(sys.content, "", &(&1.text || ""))
      assert text =~ "BASE"
      assert text =~ "<env>"

      # the STORED context must not have gained the volatile block
      [%ReqLLM.Message{content: stored} | _] = ReqLLM.Context.to_list(context)
      refute Enum.map_join(stored, "", &(&1.text || "")) =~ "<env>"
      assert length(ReqLLM.Context.to_list(context)) == 2
    end

    test "is a no-op on a context with no system message" do
      context = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))
      assert Prompt.with_environment(context, "m", "/tmp") == context
    end
  end

  describe "todos_block/1" do
    test "one [status] line per item" do
      block = Prompt.todos_block([%{"content" => "Fix parser", "status" => "in_progress"}])
      assert block =~ "- [in_progress] Fix parser"
    end

    test "renders agent-private notes as an indented sub-line" do
      block =
        Prompt.todos_block([
          %{"content" => "Fix parser", "status" => "in_progress", "notes" => "a.ex:42\n13 fails"}
        ])

      assert block =~ "- [in_progress] Fix parser"
      assert block =~ "\n    a.ex:42"
      assert block =~ "\n    13 fails"
    end

    test "an item with no notes has no sub-line" do
      block = Prompt.todos_block([%{"content" => "A", "status" => "pending"}])
      refute block =~ "\n    "
    end
  end
end
