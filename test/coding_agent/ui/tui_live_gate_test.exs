defmodule CodingAgent.UI.TuiLiveGateTest do
  use ExUnit.Case, async: false

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

    Process.sleep(50)

    assert :sys.get_state(pid).user_state.pending == []

    # the REAL gate path: debug_gate interrupts the session and
    # broadcasts with the pending calls — exactly what a live run does
    :ok =
      CodingAgent.Core.Session.debug_gate(sid, [
        %{id: "c1", name: "write_file", arguments: %{"path" => "x.txt", "content" => "hi"}}
      ])

    wait_until(fn -> :sys.get_state(pid).user_state.pending != [] end)
    assert length(:sys.get_state(pid).user_state.pending) == 1
    assert :sys.get_state(pid).user_state.status == :interrupted

    # y approves through the async decide task (never blocks the TUI)
    :ok =
      ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{
        code: "y",
        kind: "press",
        modifiers: []
      })

    # optimistic close, then the reply settles the status. The reply
    # Task races the approved tool's file write — wait on the STATUS
    # (the reply carries it), not the file
    wait_until(fn ->
      :sys.get_state(pid).user_state.status == :idle
    end)

    assert File.exists?(Path.join(root, "x.txt"))
    assert :sys.get_state(pid).user_state.last_error == nil
  end

  defp wait_until(fun, tries \\ 150) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      wait_until(fun, tries - 1)
    end
  end
end
