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

  test "the plan agent removes write/exec tools from the registry" do
    start("wiring-plan", agent: "plan")
    {:ok, state} = Session.state("wiring-plan")

    assert state.agent.name == "plan"

    # disallowedTools: edit, write_file, shell, git
    disabled = Permissions.disabled(state.policy)
    assert "edit" in disabled
    assert "write_file" in disabled
    assert "shell" in disabled
    assert "git" in disabled
  end

  test "the plan agent's tool set has no write/exec tools" do
    start("wiring-plan-tools", agent: "plan")
    {:ok, state} = Session.state("wiring-plan-tools")

    # current_tools/1 is private; assert on the policy + the registry the
    # session would expose: disabled names are filtered from Tools.all/1.
    tools = CodingAgent.Core.Tools.all(%{root: @tmp_root})
    disabled = Permissions.disabled(state.policy)
    visible = Enum.reject(tools, &(&1.name in disabled))
    names = Enum.map(visible, & &1.name)

    refute "edit" in names
    refute "write_file" in names
    refute "shell" in names
    refute "git" in names
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

  defp system_text(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t || ""
      _ -> ""
    end)
  end

  defp system_text(%ReqLLM.Message{content: c}) when is_binary(c), do: c
  defp system_text(_), do: ""
end
