defmodule CodingAgent.UI.TuiFilePickerTest do
  @moduledoc """
  The `@`-file picker (ADR 032): `@` at a word boundary opens a popup of
  confined fd files, typing filters, enter inserts the path.
  """
  use CodingAgent.TuiCase, async: true

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

  test "@ at a word boundary opens the picker and filters" do
    if External.available?(:fd) do
      root = setup_repo()
      sid = start_session(root)
      pid = start_tui(root, sid)
      fire(pid, :__resize_poll__)

      assert sync(pid).file_popup == nil

      type(pid, "@")
      assert %{files: files} = sync(pid).file_popup
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

      type(pid, "@read")
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
end
