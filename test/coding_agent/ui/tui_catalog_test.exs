# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.TuiCatalogTest do
  @moduledoc """
  The `/catalog` hint line (ADR 039): the verb prints "refreshing the model
  catalog…" and the refresh itself is a cast, so the note is only replaced
  when an outcome arrives. `{:catalog, :unchanged}` is the outcome that used
  to be silence — a refresh that found the copy current left the note on
  screen forever, because `:updated` only comes when something changed and
  `{:failed, reason}` only when something broke.
  """
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.UI.Tui

  test "a refresh that finds nothing new ends the 'refreshing' note" do
    root = Path.join(System.tmp_dir!(), "tui-catalog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-catalog-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Session.Supervisor.start_session(
        id: sid,
        scope_root: root,
        policy: Permissions.load(nil, nil),
        test_mode: true
      )

    pid =
      start_supervised!(
        {Tui, [name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]}
      )

    # the catalog's outcome arrives as a message; `sync/1` is the mailbox
    # barrier, so the assertion does not poll
    send(pid, {:catalog, :unchanged})
    assert sync(pid).menu_note == "model catalog is up to date"
  end
end
