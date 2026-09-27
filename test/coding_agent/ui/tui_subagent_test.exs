defmodule CodingAgent.UI.TuiSubagentTest do
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.Tui

  # Subagent surfacing (ADR 017/018): the parent publishes
  # {:subagent_started, child_id, name, model}; the live band names the
  # LEAF of the active delegation while the child runs, and reverts to the
  # primary when it finishes. The child's transcript never blends into the
  # parent view (the tab view itself is a later slice).

  test "the live band names the active subagent, then the primary again" do
    root = Path.join(System.tmp_dir!(), "tui-sub-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-sub-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: sid,
        scope_root: root,
        policy: CodingAgent.Core.Permissions.load(nil, nil),
        test_mode: true,
        interactive: true
      )

    pid =
      start_supervised!(
        {Tui, [name: nil, test_mode: {120, 30}, session_id: sid, scope_root: root]}
      )

    # the primary's turn is running
    agent(pid, {:turn_started, "build"})
    agent(pid, {:status_changed, :running})

    assert Enum.any?(buffer(pid), &String.contains?(&1, "agent build"))

    # a subagent starts: the band names the leaf
    agent(pid, {:subagent_started, "child-1", "explorer", "ollama:explorer-model"})
    state = sync(pid)

    assert state.active_subagent == "child-1"
    assert Map.has_key?(state.subagents, "child-1")

    rows = buffer(pid)
    assert Enum.any?(rows, &String.contains?(&1, "agent explorer"))
    assert Enum.any?(rows, &String.contains?(&1, "model ollama:explorer-model"))

    # it finishes: the band reverts to the primary, but the TAB is KEPT
    # (finished, read-only) — the owner keeps every subagent of a session
    agent(pid, {:subagent_finished, "child-1", :ok})
    state = sync(pid)

    assert state.active_subagent == nil
    assert %{"child-1" => %{finished?: true, agent: "explorer"}} = state.subagents

    rows = buffer(pid)
    assert Enum.any?(rows, &String.contains?(&1, "agent build"))
    refute Enum.any?(rows, &String.contains?(&1, "agent explorer"))
  end

  test "a failed subagent leaves a visible note but does not break the band" do
    root = Path.join(System.tmp_dir!(), "tui-sub-fail-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-sub-fail-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: sid,
        scope_root: root,
        policy: CodingAgent.Core.Permissions.load(nil, nil),
        test_mode: true,
        interactive: true
      )

    pid =
      start_supervised!(
        {Tui, [name: nil, test_mode: {120, 30}, session_id: sid, scope_root: root]}
      )

    agent(pid, {:subagent_started, "child-x", "grumpy", "m"})
    agent(pid, {:subagent_finished, "child-x", :error})

    state = sync(pid)
    assert state.active_subagent == nil

    assert Enum.any?(state.transcript, fn
             {:info, text} -> String.contains?(text, "subagent ended with an error")
             _ -> false
           end)
  end

  # ADR 018: a child's events are tagged with the child id and routed into
  # its tab buffer — NEVER the parent transcript. The tab is read-only and
  # reuses the parent render path.
  describe "subagent tabs" do
    setup do
      root = Path.join(System.tmp_dir!(), "tui-tab-#{System.unique_integer()}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      sid = "tui-tab-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: sid,
          scope_root: root,
          policy: CodingAgent.Core.Permissions.load(nil, nil),
          test_mode: true,
          interactive: true
        )

      pid =
        start_supervised!(
          {Tui, [name: nil, test_mode: {120, 30}, session_id: sid, scope_root: root]}
        )

      %{pid: pid}
    end

    test "a child's answer accumulates in its tab, not the parent transcript", %{pid: pid} do
      agent(pid, {:subagent_started, "c1", "explorer", "m"})

      agent(pid, "c1", {:llm_deltas, "child answer"})
      agent(pid, "c1", {:llm_message, "child answer"})

      state = sync(pid)
      child = state.subagents["c1"]

      assert child.transcript == [{:assistant, "child answer"}]
      # the parent transcript saw nothing of the child's stream
      refute Enum.any?(state.transcript, fn
               {:assistant, t} -> String.contains?(t, "child answer")
               _ -> false
             end)
    end

    test "the tab bar appears only once a subagent exists", %{pid: pid} do
      refute Enum.any?(buffer(pid), &String.contains?(&1, "primary"))

      agent(pid, {:subagent_started, "c1", "explorer", "m"})
      rows = buffer(pid)
      assert Enum.any?(rows, &String.contains?(&1, "explorer"))
    end

    test "opening a tab renders the child's transcript read-only", %{pid: pid} do
      agent(pid, {:subagent_started, "c1", "explorer", "m"})
      agent(pid, "c1", {:llm_deltas, "found the bug"})
      agent(pid, "c1", {:llm_message, "found the bug"})

      # select the child tab through the popup
      state = run_menu(pid, "a")
      assert state.menu_popup_id == :subagents

      assert Enum.any?(state.menu_popup.items, fn item ->
               match?(%{id: {:tab, "c1"}}, item)
             end)

      # open the child tab directly (the popup selection path)
      selected = Enum.find(state.menu_popup.items, &match?(%{id: {:tab, "c1"}}, &1))
      :ok = open_popup_selection(pid, state, selected)

      assert sync(pid).active_tab == "c1"
      assert Enum.any?(buffer(pid), &String.contains?(&1, "found the bug"))
    end

    test "a finished tab is kept and still viewable, then back to primary", %{pid: pid} do
      agent(pid, {:subagent_started, "c1", "explorer", "m"})
      agent(pid, "c1", {:llm_deltas, "child result"})
      agent(pid, "c1", {:llm_message, "child result"})
      agent(pid, {:subagent_finished, "c1", :ok})

      # kept after finish
      assert %{"c1" => %{finished?: true}} = sync(pid).subagents

      # the popup lists the parent row AND the finished child
      state = run_menu(pid, "a")

      primary = Enum.find(state.menu_popup.items, &match?(%{id: {:tab, nil}}, &1))
      child = Enum.find(state.menu_popup.items, &match?(%{id: {:tab, "c1"}}, &1))

      assert primary
      assert child

      :ok = open_popup_selection(pid, state, child)
      assert sync(pid).active_tab == "c1"
      assert Enum.any?(buffer(pid), &String.contains?(&1, "child result"))

      # back to the parent transcript
      state = run_menu(pid, "a")
      primary = Enum.find(state.menu_popup.items, &match?(%{id: {:tab, nil}}, &1))
      :ok = open_popup_selection(pid, state, primary)

      assert sync(pid).active_tab == nil
    end
  end

  # ctrl-x <letter> fast path (fires the menu action directly).
  defp run_menu(pid, letter) do
    key(pid, "x", ["ctrl"])
    key(pid, letter)
    sync(pid)
  end

  # Drive a popup selection through the real key handler: navigate to the
  # item, then enter. The popup index is set by `state.menu_index`; move
  # with arrows so the real path is exercised.
  defp open_popup_selection(pid, state, selected) do
    index = Enum.find_index(state.menu_popup.items, &(&1 == selected))

    for _ <- 1..index//1, do: key(pid, "down")
    key(pid, "enter")
    :ok
  end
end
