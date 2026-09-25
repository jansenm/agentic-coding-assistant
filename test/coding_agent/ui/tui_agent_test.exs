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

  # The COLUMN a substring starts at, counted in graphemes (the row string
  # is UTF-8 and the panel's border "│" is 3 bytes — a byte offset would
  # be off, the lesson from `tui_cells_test`).
  defp col_of(row, needle) do
    {at, _len} = :binary.match(row, needle)

    row
    |> binary_part(0, at)
    |> String.graphemes()
    |> length()
  end

  defp write_agent(filename, frontmatter) do
    dir = Path.join([@tmp_root, ".coding-agent", "agents"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), frontmatter)
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
  # NEXT input ("agent · model") — and NOT the word "you" (owner
  # decision: the input IS the user's, the label was noise).
  test "the agent surfaces on the input footer, not the sidebar" do
    pid = start_app(agent: "build")
    buffer = Enum.join(buffer(pid), "\n")

    assert buffer =~ "build · model "
    # the sidebar no longer renders "running:"/"next:" label slots (the
    # shared agent-box redesign); identity is a badge
    refute buffer =~ "running:"
    refute buffer =~ "next:"
  end

  # Regression (review A): the agent-box footer belongs on the
  # BOTTOM-RIGHT border. The substring assertions above are
  # position-blind and did not catch it moving to the top-left when
  # agent_block/2 started delegating to Styles.panel/1.
  #
  # The composer has no frame any more (it is a filled field), so the
  # "bottom border" is now the field's LAST row, carrying the setup
  # identity ("agent · model") and nothing else: the status has moved
  # OFF this row, up into the live band above the field. The regression
  # this guards is unchanged — the identity line must be at the BOTTOM
  # of the input rect, not stacked above the text.
  test "the input footer sits on the field's last row and carries no status" do
    pid = start_app(agent: "build")
    rows = buffer(pid)

    footer_row =
      rows
      |> Enum.with_index()
      |> Enum.find(fn {r, _} -> String.contains?(r, "build · model") end)

    assert {row_text, idx} = footer_row
    # no box glyphs: the frame is gone (the "c64" report)
    refute row_text =~ "╰"
    refute row_text =~ "╭"
    # the status does NOT ride this row any more — it lives in the live
    # band, which sits ABOVE the field and shows the RUNNING session
    refute row_text =~ "idle"
    refute row_text =~ "thinking"

    band_row =
      rows
      |> Enum.with_index()
      |> Enum.find(fn {r, _} -> String.contains?(r, "○ idle") end)

    assert band_row != nil
    assert {_band_text, band_idx} = band_row
    assert band_idx < idx

    # six rows apart: the band's own bottom padding, the air row between
    # the band and the field, then the field's rows above its meta line
    # (top padding, the textarea line, the meta gap)
    assert idx - band_idx == 6

    # and the identity row is BELOW everything else in the input rect:
    # the row above it carries no identity and no typed text
    refute String.contains?(rows |> Enum.at(idx - 1), "build · model")
    refute String.contains?(rows |> Enum.at(idx + 1), "build · model")
  end

  # B4: the status panel answers "which agent handles what I type, and
  # which is running", as a row of the identity block. Its first content
  # line is the SCOPE heading (O4 dropped the " status " Block title: a
  # one-sided border painted it as bare text one cell in from the edge,
  # which read as neither heading nor content).
  test "the sidebar heads with the scope and carries the agent row" do
    pid = start_app(agent: "build")
    rows = buffer(pid)

    assert rows |> Enum.at(1) |> String.contains?(Path.basename(@tmp_root))
    # the old floating title is gone from the panel's own rows
    refute rows |> Enum.at(1) |> String.contains?("status")
    # ...and the heading is a BODY line: it sits flush with the panel's
    # content column, not one cell in from the border like a title
    heading_col = col_of(rows |> Enum.at(1), Path.basename(@tmp_root))
    label_col = col_of(rows |> Enum.at(3), "agent:")
    assert heading_col == label_col

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

    # the footer carries "agent · model"; not the generic agent fallback
    assert buffer =~ "build · model "
    refute buffer =~ "build · default"
  end

  test "with no agent the input footer shows just the model, not a (none) label" do
    pid = start_app(agent: nil)
    buffer = Enum.join(buffer(pid), "\n")

    # no agent target: the footer reads "model …" with no "→ (none)"
    assert buffer =~ "model "
    refute buffer =~ "(none)"
    refute buffer =~ "→"
    refute buffer =~ "you"
  end

  describe "the Tab list is Agent.selectable?/1 (ADR 029)" do
    test "a mode: all definition is selectable (the old == :primary filter dropped it)" do
      write_agent("helper.md", """
      ---
      description: an unpinned helper
      mode: all
      ---
      helper body
      """)

      pid = start_app(agent: "build")
      assert "helper" in sync(pid).primary_agents
    end

    test "a hidden definition is not offered by Tab" do
      write_agent("internal.md", """
      ---
      description: an internal agent
      mode: primary
      hidden: true
      ---
      internal body
      """)

      pid = start_app(agent: "build")
      refute "internal" in sync(pid).primary_agents
    end

    test "a subagent-only definition is not offered by Tab" do
      write_agent("delegate.md", """
      ---
      description: a delegated agent
      mode: subagent
      ---
      delegate body
      """)

      pid = start_app(agent: "build")
      refute "delegate" in sync(pid).primary_agents
    end
  end

  describe "the sidebar effort line (ADR 029)" do
    test "shows the session's resolved effort, not a global re-read" do
      File.mkdir_p!(Path.join(@tmp_root, ".coding-agent"))

      File.write!(
        Path.join(@tmp_root, ".coding-agent/config.toml"),
        ~s(reasoning_effort = "high")
      )

      pid = start_app(agent: "build")
      # the definition list pads labels, so match the value on its row
      assert Enum.join(buffer(pid), "\n") =~ ~r/effort:\s+high/
    end

    test "reads 'default' when nothing is configured" do
      pid = start_app(agent: "build")
      assert Enum.join(buffer(pid), "\n") =~ ~r/effort:\s+default/
    end
  end

  describe "resume restores the agent (regression)" do
    setup do
      # persist a plan session, then resume it through the picker path.
      # A UNIQUE id per test: start_session is idempotent per id, so a
      # shared id would hand the second test the first test's live
      # session (or a stale one) instead of resuming the saved snapshot.
      # the store is one SQLite DB file (ADR 020): give this suite its own
      dir = Application.get_env(:coding_agent, :store_path)
      Application.put_env(:coding_agent, :store_path, Path.join(@tmp_root, "store.db"))

      on_exit(fn -> if dir, do: Application.put_env(:coding_agent, :store_path, dir) end)

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
