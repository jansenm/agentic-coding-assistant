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

  test "Tab cycles back to build after the last primary (never (none))" do
    pid = start_app(agent: "build")

    # plan is the last primary; Tab wraps to the FIRST primary again,
    # never to the no-agent default.
    TuiAgentTest.press(pid, "tab")
    TuiAgentTest.press(pid, "tab")

    assert sync(pid).next_agent == "build"
  end

  test "the switch takes effect in the session (tools change)" do
    pid = start_app(agent: "build")
    TuiAgentTest.press(pid, "tab")

    id = sync(pid).session_id
    {:ok, st} = CodingAgent.Core.Session.state(id)
    assert st.agent.name == "plan"
    assert "edit" in CodingAgent.Core.Permissions.disabled(st.policy)
  end

  # Attribution lives at the message-box footers and the input footer
  # (the shared "agent box" design): the sidebar no longer carries
  # running/next/model slots. The input footer shows the target of the
  # NEXT input ("you → agent") plus the effective model.
  test "the agent surfaces on the input footer, not the sidebar" do
    pid = start_app(agent: "build")
    buffer = Enum.join(buffer(pid), "\n")

    assert buffer =~ "you → build"
    # the sidebar no longer renders running/next slots (removed in the
    # shared agent-box redesign)
    refute buffer =~ "running:"
    refute buffer =~ "next:"
  end

  test "the input footer shows the agent and the model it would use" do
    pid = start_app(agent: "build")
    buffer = Enum.join(buffer(pid), "\n")

    # the footer carries "you → agent · model"; no agent-less "default"
    assert buffer =~ "you → build · "
    refute buffer =~ "you → default"
  end

  test "with no agent the input footer shows just 'you', not a (none) label" do
    pid = start_app(agent: nil)
    buffer = Enum.join(buffer(pid), "\n")

    # no agent target: the footer reads "you · model" with no "→ (none)"
    assert buffer =~ "you · "
    refute buffer =~ "you → (none)"
    refute buffer =~ "you → default"
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

    test "Tab from a resumed plan switches to build (no sticky narrowing)", %{resume_id: id} do
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

      # plan is the last primary, so Tab wraps to build — the full-tool
      # agent — proving the switch recomputes from base (no sticky
      # narrowing), instead of cycling to a no-agent default.
      TuiAgentTest.press(pid, "tab")
      sid = sync(pid).session_id

      {:ok, st} = CodingAgent.Core.Session.state(sid)
      assert st.agent.name == "build"
      assert CodingAgent.Core.Permissions.disabled(st.policy) == []
    end
  end

  def press(pid, code), do: key(pid, code)
end
