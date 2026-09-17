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
      {Tui, [name: nil, test_mode: {90, 30}, scope_root: @tmp_root, sidebar: true] ++ opts}
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

  test "each slot shows the agent and the model it would use" do
    pid = start_app(agent: "build")
    buffer = Enum.join(buffer(pid), "\n")

    # both slots carry "name · model"; no agent-less "default" label
    assert buffer =~ "running: build · "
    assert buffer =~ "next:    build · "
    refute buffer =~ "running: default"
    refute buffer =~ "next:    default"
  end

  test "with no agent the slots say (none), not the ambiguous 'default'" do
    pid = start_app(agent: nil)
    buffer = Enum.join(buffer(pid), "\n")

    assert buffer =~ "(none)"
    # 'default' is still used for effort, but not as an agent label
    refute buffer =~ "running: default"
  end

  describe "resume restores the agent (regression)" do
    setup do
      # persist a plan session, then resume it through the picker path.
      # A UNIQUE id per test: start_session is idempotent per id, so a
      # shared id would hand the second test the first test's live
      # session (or a stale one) instead of resuming the saved snapshot.
      dir = Application.get_env(:coding_agent, :store_dir)
      Application.put_env(:coding_agent, :store_dir, @tmp_root)

      on_exit(fn -> if dir, do: Application.put_env(:coding_agent, :store_dir, dir) end)

      id = "resume-agent-#{System.unique_integer([:positive])}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true,
          agent: "plan"
        )

      {:ok, state} = CodingAgent.Core.Session.state(id)
      :ok = CodingAgent.Core.Session.Store.save(state)

      # the id is stored under the test id; expose it to the tests
      {:ok, resume_id: id}
    end

    test "the restored session keeps its agent", %{resume_id: id} do
      pid =
        start_supervised!(
          {Tui,
           [
             name: nil,
             test_mode: {90, 30},
             scope_root: @tmp_root,
             sidebar: true,
             resume_id: id
           ]}
        )

      state = sync(pid)
      assert state.running_agent == "plan"
      assert state.next_agent == "plan"
    end

    test "Tab from a resumed plan restores the tools (no sticky narrowing)", %{resume_id: id} do
      pid =
        start_supervised!(
          {Tui,
           [
             name: nil,
             test_mode: {90, 30},
             scope_root: @tmp_root,
             sidebar: true,
             resume_id: id
           ]}
        )

      # plan is the last primary, so Tab cycles to the no-agent default
      TuiAgentTest.press(pid, "tab")
      sid = sync(pid).session_id

      {:ok, st} = CodingAgent.Core.Session.state(sid)
      assert st.agent == nil
      assert CodingAgent.Core.Permissions.disabled(st.policy) == []
    end
  end

  def press(pid, code), do: key(pid, code)
end
