# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.TuiFilePickerTest do
  @moduledoc """
  The `@`-file picker (ADR 032): `@` at a word boundary opens a popup of
  confined fd files, typing filters, enter inserts the path.
  """
  # `async: false` because two tests here flip `External.put(:fd, …)`, a
  # PROCESS-GLOBAL `:persistent_term` memo. Async, that lie was visible to
  # any concurrent reader — measured: `GrepGlobTest`'s "skips files over
  # 1 MiB" lost its "skipped: 1 file(s)" note (the note is built from the
  # `fd` probe, and `grep` turns a failed probe into "nothing was
  # skipped") and failed under full-suite load, while passing alone.
  use CodingAgent.TuiCase, async: false

  alias CodingAgent.Core.External
  alias CodingAgent.Core.Permissions
  alias CodingAgent.UI.Tui

  defp setup_repo do
    root = Path.join(System.tmp_dir!(), "tui-at-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/alpha.ex"), "a\n")
    File.write!(Path.join(root, "lib/beta.ex"), "b\n")
    File.write!(Path.join(root, "README.md"), "x\n")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp start_session(root) do
    sid = "tui-at-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: sid,
        scope_root: root,
        policy: Permissions.load(nil, nil),
        test_mode: true
      )

    sid
  end

  defp start_tui(root, sid) do
    start_supervised!(%{
      id: String.to_atom("tui-at-#{System.unique_integer([:positive])}"),
      start:
        {Tui, :start_link, [[name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]]}
    })
  end

  defp type(pid, text) do
    Enum.each(String.graphemes(text), fn ch -> key(pid, ch) end)
  end

  # The fetch is async (review F8): wait until the popup left its loading
  # state before asserting on the (possibly empty) matches.
  defp wait_loaded(pid) do
    wait_until(fn ->
      case sync(pid).file_popup do
        %{loading: false} -> true
        _ -> false
      end
    end)
  end

  test "@ at a word boundary opens the picker and filters" do
    if External.available?(:fd) do
      root = setup_repo()
      sid = start_session(root)
      pid = start_tui(root, sid)
      fire(pid, :__resize_poll__)

      assert sync(pid).file_popup == nil

      type(pid, "@")
      # the loading popup appears at once, then fills in
      wait_loaded(pid)
      assert %{prepared: prepared} = sync(pid).file_popup
      files = Enum.map(prepared, &elem(&1, 0))
      refute files == []
      assert Enum.any?(files, &(&1 == "lib/alpha.ex"))

      # typing narrows the query
      type(pid, "alpha")
      popup = sync(pid).file_popup
      assert popup.query == "alpha"
      assert popup.matches == ["lib/alpha.ex"]
    else
      :ok
    end
  end

  test "enter inserts the selected path and closes the picker" do
    if External.available?(:fd) do
      root = setup_repo()
      sid = start_session(root)
      pid = start_tui(root, sid)
      fire(pid, :__resize_poll__)

      type(pid, "@")
      wait_loaded(pid)
      type(pid, "read")
      assert sync(pid).file_popup.matches == ["README.md"]

      key(pid, "enter")

      assert sync(pid).file_popup == nil
      assert ExRatatui.textarea_get_value(sync(pid).textarea) == "@README.md "
    else
      :ok
    end
  end

  test "esc closes the picker without inserting" do
    if External.available?(:fd) do
      root = setup_repo()
      sid = start_session(root)
      pid = start_tui(root, sid)
      fire(pid, :__resize_poll__)

      type(pid, "@")
      key(pid, "esc")

      assert sync(pid).file_popup == nil
      assert ExRatatui.textarea_get_value(sync(pid).textarea) == ""
    else
      :ok
    end
  end

  test "esc cancels an in-flight fetch (review F4)" do
    root = setup_repo()
    sid = start_session(root)
    pid = start_tui(root, sid)
    fire(pid, :__resize_poll__)

    # Block the fetch so the popup stays loading and we can hold its pid:
    # a stub "fd" that ignores its args and sleeps past the assertion.
    stub = Path.join(root, "slow-fd")
    File.write!(stub, "#!/bin/sh\nsleep 30\n")
    File.chmod!(stub, 0o755)

    saved = External.probe(:fd)
    External.put(:fd, {:ok, stub})
    on_exit(fn -> External.put(:fd, saved) end)

    type(pid, "@")
    assert %{pid: fetch_pid} = sync(pid).file_popup
    assert is_pid(fetch_pid)

    key(pid, "esc")
    assert sync(pid).file_popup == nil
    # the enumeration process is killed, not left running to the timeout
    wait_until(fn -> not Process.alive?(fetch_pid) end)
  end

  test "@ mid-word is plain text" do
    root = setup_repo()
    sid = start_session(root)
    pid = start_tui(root, sid)
    fire(pid, :__resize_poll__)

    type(pid, "foo")
    type(pid, "@")
    assert sync(pid).file_popup == nil
    assert ExRatatui.textarea_get_value(sync(pid).textarea) == "foo@"
  end

  test "the picker owns the keyboard: ctrl-x does not reach the menu (review F6)" do
    if External.available?(:fd) do
      root = setup_repo()
      sid = start_session(root)
      pid = start_tui(root, sid)
      fire(pid, :__resize_poll__)

      type(pid, "@")
      wait_loaded(pid)

      # ctrl-x used to arm the menu prefix and ctrl-x q QUIT the TUI.
      key(pid, "x", ["ctrl"])
      assert Process.alive?(pid)
      assert sync(pid).menu_pending == false
      assert sync(pid).file_popup != nil

      key(pid, "q")
      assert Process.alive?(pid)
      # q is a picker query char, not a quit
      assert sync(pid).file_popup.query == "q"
    else
      :ok
    end
  end

  test "a fetch error re-inserts the typed @ (review F7)" do
    root = setup_repo()
    sid = start_session(root)
    pid = start_tui(root, sid)
    fire(pid, :__resize_poll__)

    saved = External.probe(:fd)
    External.put(:fd, :error)
    on_exit(fn -> External.put(:fd, saved) end)

    type(pid, "@")

    wait_until(fn ->
      sync(pid).file_popup == nil and ExRatatui.textarea_get_value(sync(pid).textarea) == "@"
    end)

    assert ExRatatui.textarea_get_value(sync(pid).textarea) == "@"
  end
end
