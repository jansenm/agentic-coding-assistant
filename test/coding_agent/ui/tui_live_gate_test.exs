defmodule CodingAgent.UI.TuiLiveGateTest do
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.Tui

  # The 5b tests exercised approval by STARTING the app after the gate
  # already interrupted (mount pulled pending). This test does it the
  # LIVE way: the app is running, THEN the gate pauses the session —
  # pending must arrive via the status_changed broadcast (found broken
  # by the user's first live interactive session: handle_info dropped
  # the pending detail, so the dialog never appeared).

  test "gate interrupt mid-run reaches the TUI; y approves through the async decide" do
    root = Path.join(System.tmp_dir!(), "tui-live-gate-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    # repo-side ask policy: the 2026-09-15 amendment made write_file
    # allow-by-default, and this test is about the PAUSE path
    toml_path = Path.join(root, "permissions.toml")

    File.write!(toml_path, """
    [permissions.write_file]
    "*" = "ask"
    """)

    sid = "tui-live-gate-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: sid,
        scope_root: root,
        policy: CodingAgent.Core.Permissions.load(nil, toml_path),
        test_mode: true
      )

    pid =
      start_supervised!(
        {Tui, [name: nil, test_mode: {80, 24}, session_id: sid, scope_root: root]}
      )

    assert sync(pid).pending == []

    # the REAL gate path: debug_gate interrupts the session and
    # broadcasts with the pending calls — exactly what a live run does
    :ok =
      CodingAgent.Core.Session.debug_gate(sid, [
        %{id: "c1", name: "write_file", arguments: %{"path" => "x.txt", "content" => "hi"}}
      ])

    wait_until(fn -> sync(pid).pending != [] end)
    assert length(sync(pid).pending) == 1
    assert sync(pid).status == :interrupted

    # y approves through the async decide task (never blocks the TUI)
    key(pid, "y")

    # optimistic close, then the reply settles the status. The reply
    # Task races the approved tool's file write — wait on the STATUS
    # (the reply carries it), not the file
    wait_until(fn -> sync(pid).status == :idle end)

    assert File.exists?(Path.join(root, "x.txt"))
    assert sync(pid).last_error == nil
  end

  # Found live: a second gated call in the SAME turn never showed its
  # dialog. The human answered the first `webfetch`, and when the decide
  # worker requested the next one the band read "approval needed" but no
  # dialog appeared — the app had to be restarted. The decide path emits
  # no status broadcast, so the optimistic `deciding?: true` from the `y`
  # key press survived into the new park and `dialog_widgets/2` rendered
  # nothing. This drives the exact event order (no intervening
  # non-:interrupted status) and asserts the dialog is visible again.
  test "a SECOND live gate pause in the same turn reopens the dialog" do
    root = Path.join(System.tmp_dir!(), "tui-live-gate2-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    toml_path = Path.join(root, "permissions.toml")

    File.write!(toml_path, """
    [permissions.write_file]
    "*" = "ask"
    """)

    sid = "tui-live-gate2-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: sid,
        scope_root: root,
        policy: CodingAgent.Core.Permissions.load(nil, toml_path),
        test_mode: true,
        model: "openai:gpt-4o"
      )

    pid =
      start_supervised!(
        {Tui, [name: nil, test_mode: {80, 24}, session_id: sid, scope_root: root]}
      )

    call2 = %{id: "c2", name: "write_file", arguments: %{"path" => "b.txt", "content" => "b"}}

    # first pause (live broadcast), answered with `y`
    :ok =
      CodingAgent.Core.Session.debug_gate(sid, [
        %{id: "c1", name: "write_file", arguments: %{"path" => "a.txt", "content" => "a"}}
      ])

    wait_until(fn -> sync(pid).pending != [] end)
    key(pid, "y")

    # let the approved write finish so the spawned tool process is not
    # still cding when the test's on_exit removes the scope root
    wait_until(fn -> File.exists?(Path.join(root, "a.txt")) end)

    # The decide path emits no status broadcast, so the park on the NEXT
    # gated call arrives as the only event — no non-:interrupted status in
    # between. The dialog must re-open: `deciding?` is cleared by the park
    # and the calls come from the broadcast.
    send(pid, {:agent, {:status_changed, :interrupted, [call2]}})

    wait_until(fn -> sync(pid).pending == [call2] end)

    state = sync(pid)
    assert state.pending == [call2]
    refute state.deciding?, "deciding? stuck true after a decide led into a new pause"
  end
end
