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

    # it finishes: the band reverts to the primary
    agent(pid, {:subagent_finished, "child-1", :ok})
    state = sync(pid)

    assert state.active_subagent == nil
    assert state.subagents == %{}

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
end
