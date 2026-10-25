defmodule CodingAgent.UI.TuiBudgetTest do
  use CodingAgent.TuiCase, async: true

  import ExUnit.CaptureLog

  alias CodingAgent.UI.Tui

  # The budget prompt (ADR 025): an INTERACTIVE session pauses at the
  # round budget and the TUI shows a continue/stop dialog. Rendered live
  # via the status_changed broadcast, like the approval gate.

  test "the budget pause reaches the TUI; n stops through the async decision" do
    root = Path.join(System.tmp_dir!(), "tui-budget-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-budget-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {80, 24}, session_id: sid, scope_root: root]}
      )

    assert sync(pid).budget_prompt == nil

    # trip the budget: debug_gate with rounds at the default 100
    log =
      capture_log(fn ->
        :ok =
          CodingAgent.Core.Session.debug_gate(
            sid,
            [
              %{
                id: "b1",
                name: "write_file",
                arguments: %{"path" => "held.txt", "content" => "x"}
              }
            ],
            rounds: 100
          )
      end)

    # the pause is a logged event (the dialog is the human-facing half)
    assert log =~ "tool-round budget reached: 100 (asking)"

    wait_until(fn -> sync(pid).budget_prompt != nil end)
    assert sync(pid).budget_prompt.budget == 100
    assert sync(pid).status == :interrupted

    # n = stop: the held round is discarded and the turn wraps up — and the
    # wrap-up says so in the log
    log =
      capture_log(fn ->
        key(pid, "n")
        wait_until(fn -> sync(pid).budget_prompt == nil and sync(pid).status == :idle end)
      end)

    assert log =~ "tool-round budget reached: 100"
    refute File.exists?(Path.join(root, "held.txt"))
  end

  test "y continues and the held round runs" do
    root = Path.join(System.tmp_dir!(), "tui-budget-c-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-budget-c-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {80, 24}, session_id: sid, scope_root: root]}
      )

    log =
      capture_log(fn ->
        :ok =
          CodingAgent.Core.Session.debug_gate(
            sid,
            [
              %{
                id: "b2",
                name: "write_file",
                arguments: %{"path" => "cont.txt", "content" => "y"}
              }
            ],
            rounds: 100
          )

        wait_until(fn -> sync(pid).budget_prompt != nil end)
      end)

    assert log =~ "tool-round budget reached: 100 (asking)"

    log =
      capture_log(fn ->
        key(pid, "y")
        wait_until(fn -> File.exists?(Path.join(root, "cont.txt")) end)
      end)

    # the continuation itself is not a budget event (only the trip is)
    refute log =~ "tool-round budget reached"
    assert File.read!(Path.join(root, "cont.txt")) == "y"
  end

  test "the doom prompt reaches the TUI; n rejects through the async decision" do
    root = Path.join(System.tmp_dir!(), "tui-doom-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-doom-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {80, 24}, session_id: sid, scope_root: root]}
      )

    assert sync(pid).doom_prompt == nil

    call = %{id: "d1", name: "read_file", arguments: %{"path" => "same.txt"}}
    :ok = CodingAgent.Core.Session.debug_gate(sid, [call])
    :ok = CodingAgent.Core.Session.debug_gate(sid, [%{call | id: "d2"}])
    :ok = CodingAgent.Core.Session.debug_gate(sid, [%{call | id: "d3"}])

    wait_until(fn -> sync(pid).doom_prompt != nil end)
    assert sync(pid).doom_prompt.tool == "read_file"
    assert sync(pid).status == :interrupted

    key(pid, "n")
    wait_until(fn -> sync(pid).doom_prompt == nil end)
  end

  test "a late budget reply cannot close the NEXT pause (same race as the question dialog)" do
    # The same bug class ADR 027 found for the question wizard: the
    # decision reply arrives AFTER the worker already parked on the next
    # pause, whose broadcast opened the fresh dialog. The reply must not
    # clear it.
    root = Path.join(System.tmp_dir!(), "tui-budget-race-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-budget-race-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]}
      )

    # the first pause opens; the user continues (optimistic close)
    agent(pid, {:status_changed, :budget_reached, %{budget: 100}})
    assert sync(pid).budget_prompt != nil

    agent(pid, {:status_changed, :running})
    assert sync(pid).budget_prompt == nil

    # the next pause opens before the reply lands
    agent(pid, {:status_changed, :doom_reached, %{tool: "read_file"}})
    assert sync(pid).doom_prompt != nil

    send(pid, {:__budget_decided__, {:ok, :interrupted}})
    state = sync(pid)

    assert state.doom_prompt != nil, "the late budget reply must not close the doom prompt"
    assert state.status == :interrupted
  end
end
