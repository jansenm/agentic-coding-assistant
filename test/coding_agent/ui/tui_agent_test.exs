defmodule CodingAgent.UI.TuiAgentTest do
  use CodingAgent.TuiCase, async: false

  alias CodingAgent.UI.Tui
  alias CodingAgent.UI.TuiAgentTest

  @tmp_root System.tmp_dir!() |> Path.join("tui-agent-#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    :ok
  end

  defp start_app(opts) do
    start_supervised!(
      {Tui,
       [name: nil, test_mode: {90, 30}, scope_root: @tmp_root, sidebar: true] ++ opts}
    )
  end

  test "the two slots start from the mounted agent" do
    pid = start_app(agent: "build")
    state = sync(pid)

    assert state.running_agent == "build"
    assert state.next_agent == "build"
    assert "build" in state.primary_agents
    assert "plan" in state.primary_agents
  end

  test "Tab switches next_agent to the next primary" do
    pid = start_app(agent: "build")

    TuiAgentTest.press(pid, "tab")
    state = sync(pid)

    assert state.next_agent == "plan"
    # the running slot follows while idle
    assert state.running_agent == "plan"
  end

  test "Tab cycles back to default after the last primary" do
    pid = start_app(agent: "build")

    TuiAgentTest.press(pid, "tab")
    TuiAgentTest.press(pid, "tab")

    assert sync(pid).next_agent == nil
  end

  test "the switch takes effect in the session (tools change)" do
    pid = start_app(agent: "build")
    TuiAgentTest.press(pid, "tab")

    id = sync(pid).session_id
    {:ok, st} = CodingAgent.Core.Session.state(id)
    assert st.agent.name == "plan"
    assert "edit" in CodingAgent.Core.Permissions.disabled(st.policy)
  end

  test "the sidebar renders both slots" do
    pid = start_app(agent: "build")
    buffer = Enum.join(buffer(pid), "\n")

    assert buffer =~ "running:"
    assert buffer =~ "next:"
    assert buffer =~ "build"
  end

  def press(pid, code), do: key(pid, code)
end
