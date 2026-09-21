defmodule CodingAgent.Core.Session.AgentWiringTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session

  @tmp_root System.tmp_dir!() |> Path.join("agent-wiring-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  defp start(id, opts) do
    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        Keyword.merge([id: id, scope_root: @tmp_root, test_mode: true], opts)
      )
  end

  test "no :agent keeps the pre-agent behaviour (nil agent, default policy)" do
    start("wiring-none", [])
    {:ok, state} = Session.state("wiring-none")

    assert state.agent == nil
    assert Permissions.enabled(state.policy) == :default
    assert Permissions.disabled(state.policy) == []
  end

  test "a named agent is resolved and recorded on the state" do
    start("wiring-build", agent: "build")
    {:ok, state} = Session.state("wiring-build")

    assert state.agent.name == "build"
    assert state.agent.mode == :primary
  end

  test "the plan agent removes the write tools but keeps a read-only shell" do
    start("wiring-plan", agent: "plan")
    {:ok, state} = Session.state("wiring-plan")

    assert state.agent.name == "plan"

    # disallowedTools: edit, write_file, git — shell stays, but read-only
    disabled = Permissions.disabled(state.policy)
    assert "edit" in disabled
    assert "write_file" in disabled
    assert "git" in disabled
    refute "shell" in disabled
    assert Permissions.shell_mode(state.policy) == :ro
  end

  test "the plan agent keeps read tools and a shell, but no write tools" do
    start("wiring-plan-tools", agent: "plan")
    {:ok, state} = Session.state("wiring-plan-tools")

    tools = CodingAgent.Core.Tools.all(%{root: @tmp_root})
    disabled = Permissions.disabled(state.policy)
    visible = Enum.reject(tools, &(&1.name in disabled))
    names = Enum.map(visible, & &1.name)

    refute "edit" in names
    refute "write_file" in names
    refute "git" in names
    assert "shell" in names
    assert "read_file" in names
    assert "grep" in names
    assert "glob" in names
  end

  test "the agent prompt is composed onto the framework prompt" do
    start("wiring-prompt", agent: "plan")
    {:ok, state} = Session.state("wiring-prompt")

    system =
      state.context
      |> ReqLLM.Context.to_list()
      |> Enum.find(&(&1.role == :system))

    text = system_text(system)
    assert text =~ "coding assistant"
    assert text =~ "planning agent"
  end

  test "an unknown agent name is a hard error" do
    assert {:error, _} =
             CodingAgent.Core.Session.Supervisor.start_session(
               id: "wiring-bogus",
               scope_root: @tmp_root,
               test_mode: true,
               agent: "does-not-exist"
             )
  end

  describe "set_agent/2 (ADR 018 next-slot switch)" do
    test "switches the agent and its tool restrictions" do
      start("switch-a", agent: "build")
      assert {:ok, s} = Session.set_agent("switch-a", "plan")

      assert s.agent.name == "plan"
      assert "edit" in Permissions.disabled(s.policy)
      assert Permissions.shell_mode(s.policy) == :ro
    end

    test "switching back does not compound restrictions" do
      start("switch-b", agent: "plan")
      {:ok, _} = Session.set_agent("switch-b", "build")
      {:ok, s} = Session.set_agent("switch-b", "plan")

      # exactly plan's three denied tools, not plan-on-plan accumulation
      assert Enum.sort(Permissions.disabled(s.policy)) == ["edit", "git", "write_file"]
      assert Permissions.shell_mode(s.policy) == :ro
    end

    test "clearing the agent restores the base policy" do
      start("switch-c", agent: "plan")
      {:ok, s} = Session.set_agent("switch-c", nil)

      assert s.agent == nil
      assert Permissions.disabled(s.policy) == []
      # the read-only shell was the DEFINITION's, not the session's
      assert Permissions.shell_mode(s.policy) == :rw
    end

    test "the system prompt follows the agent" do
      start("switch-d", agent: "build")
      {:ok, s} = Session.set_agent("switch-d", "plan")

      assert system_text_of(s) =~ "planning agent"
    end

    test "an unknown agent returns an error and leaves the state alone" do
      start("switch-e", agent: "build")
      assert {:error, {:unknown_agent, "nope", _}} = Session.set_agent("switch-e", "nope")

      {:ok, s} = Session.state("switch-e")
      assert s.agent.name == "build"
    end
  end

  describe "effective_model/1 (ADR 017 model field)" do
    test "an agent without a model uses the session model" do
      start("model-none", agent: "build")
      {:ok, s} = Session.state("model-none")

      refute s.agent.model
      assert Session.effective_model(s) == s.model
    end

    test "an agent with its own model wins over the session model" do
      # build a state directly: the loader only reads files, so this is
      # the unit-level check of the precedence
      agent = %CodingAgent.Core.Agent{
        name: "cheap",
        prompt: "p",
        source: "test",
        model: "ollama:tiny"
      }

      state = %CodingAgent.Core.Session.State{
        id: "m",
        context: ReqLLM.Context.new(),
        model: "ollama_cloud:glm",
        status: :idle,
        agent: agent
      }

      assert Session.effective_model(state) == "ollama:tiny"
    end

    test "no agent at all uses the session model" do
      state = %CodingAgent.Core.Session.State{
        id: "m",
        context: ReqLLM.Context.new(),
        model: "ollama_cloud:glm",
        status: :idle,
        agent: nil
      }

      assert Session.effective_model(state) == "ollama_cloud:glm"
    end
  end

  defp system_text_of(state) do
    state.context
    |> ReqLLM.Context.to_list()
    |> Enum.find(&(&1.role == :system))
    |> system_text()
  end

  defp system_text(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t || ""
      _ -> ""
    end)
  end

  defp system_text(%ReqLLM.Message{content: c}) when is_binary(c), do: c
  defp system_text(_), do: ""
end
