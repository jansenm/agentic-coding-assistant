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
end
