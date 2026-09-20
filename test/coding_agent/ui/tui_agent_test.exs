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
    # the sidebar no longer renders "running:"/"next:" label slots (the
    # shared agent-box redesign); identity is a badge
    refute buffer =~ "running:"
    refute buffer =~ "next:"
  end

  # Regression (review A): the agent-box footer belongs on the
  # BOTTOM-RIGHT border. The substring assertions above are
  # position-blind and did not catch it moving to the top-left when
  # agent_block/2 started delegating to Styles.panel/1.
  test "the input footer sits on the bottom border, right-aligned" do
    pid = start_app(agent: "build")
    rows = buffer(pid)

    footer_row =
      rows
      |> Enum.with_index()
      |> Enum.find(fn {r, _} -> String.contains?(r, "you → build") end)

    assert {row_text, idx} = footer_row
    # bottom border: the row after it starts the status line (no box row
    # below the footer); the footer row carries the rounded bottom glyph
    assert String.contains?(row_text, "╰")
    # right-aligned: the footer hugs the right edge, no box content after
    assert String.trim_trailing(row_text) |> String.ends_with?("╯")
    # and it is NOT the top border (the old regression put it there)
    refute String.contains?(rows |> Enum.at(idx - 1), "you → build")
  end

  # B4: the status panel answers "which agent handles what I type, and
  # which is running", as a badge. Its title is truthful ("status", not
  # "agent" — it holds session/effort/token data).
  test "the sidebar is titled status and carries the agent badge" do
    pid = start_app(agent: "build")
    rows = buffer(pid)

    assert rows |> Enum.at(1) |> String.contains?("status")
    refute rows |> Enum.at(1) |> String.contains?("agent╯")

    buffer = Enum.join(rows, "\n")
    assert buffer =~ "build"
  end

  test "while a turn runs, the running agent shows in the panel" do
    pid = start_app(agent: "build")

    agent(pid, {:turn_started, "build"})
    agent(pid, {:status_changed, :running})

    assert Enum.join(buffer(pid), "\n") =~ "build running"
  end

  test "running and next agents both show when they differ" do
    pid = start_app(agent: "build")

    agent(pid, {:turn_started, "build"})
    agent(pid, {:status_changed, :running})

    # Tab while running only changes the NEXT input's agent (ADR 018)
    TuiAgentTest.press(pid, "tab")
    assert sync(pid).next_agent == "plan"

    buffer = Enum.join(buffer(pid), "\n")
    assert buffer =~ "build running"
    assert buffer =~ "plan next"
  end

  test "when idle, only the next agent shows (no stale 'running')" do
    pid = start_app(agent: "build")

    agent(pid, {:turn_started, "build"})
    agent(pid, {:status_changed, :idle})

    buffer = Enum.join(buffer(pid), "\n")
    refute buffer =~ "running"
    assert buffer =~ "build"
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
      # the store is one SQLite DB file (ADR 020): give this suite its own
      dir = Application.get_env(:coding_agent, :store_dir)
      Application.put_env(:coding_agent, :store_dir, Path.join(@tmp_root, "store.db"))

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
