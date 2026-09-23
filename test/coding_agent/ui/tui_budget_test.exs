defmodule CodingAgent.UI.TuiBudgetTest do
  use CodingAgent.TuiCase, async: true

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
    :ok =
      CodingAgent.Core.Session.debug_gate(
        sid,
        [%{id: "b1", name: "write_file", arguments: %{"path" => "held.txt", "content" => "x"}}],
        rounds: 100
      )

    wait_until(fn -> sync(pid).budget_prompt != nil end)
    assert sync(pid).budget_prompt.budget == 100
    assert sync(pid).status == :interrupted

    # n = stop: the held round is discarded and the turn wraps up
    key(pid, "n")

    wait_until(fn -> sync(pid).budget_prompt == nil and sync(pid).status == :idle end)
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

    :ok =
      CodingAgent.Core.Session.debug_gate(
        sid,
        [%{id: "b2", name: "write_file", arguments: %{"path" => "cont.txt", "content" => "y"}}],
        rounds: 100
      )

    wait_until(fn -> sync(pid).budget_prompt != nil end)

    key(pid, "y")
    wait_until(fn -> File.exists?(Path.join(root, "cont.txt")) end)
    assert File.read!(Path.join(root, "cont.txt")) == "y"
  end
end
