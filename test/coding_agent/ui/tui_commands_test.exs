defmodule CodingAgent.UI.TuiCommandsTest do
  @moduledoc """
  The `/` command palette and typed-command execution (ADR 034).
  """
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.Tui

  setup do
    root = System.tmp_dir!() |> Path.join("tui-cmd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp start_tui(root) do
    start_supervised!(%{
      id: String.to_atom("tui-cmd-#{System.unique_integer([:positive])}"),
      start: {Tui, :start_link, [[name: nil, test_mode: {100, 30}, scope_root: root]]}
    })
  end

  defp type(pid, text) do
    Enum.each(String.graphemes(text), fn ch -> key(pid, ch) end)
  end

  test "/ at a word boundary opens the palette, typing filters", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    assert sync(pid).command_popup == nil

    type(pid, "/")
    popup = sync(pid).command_popup
    assert length(popup.matches) > 3

    type(pid, "mod")
    popup = sync(pid).command_popup
    assert popup.query == "mod"
    assert Enum.map(popup.matches, & &1.name) == ["model"]
  end

  test "the palette renders the usage lines", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    type(pid, "/")
    body = Enum.join(buffer(pid), "\n")
    assert body =~ "/sessions"
    assert body =~ "switch session"
  end

  test "enter runs the selected command", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    type(pid, "/keymaps")
    assert sync(pid).command_popup.matches |> Enum.map(& &1.name) == ["keymaps"]

    key(pid, "enter")

    st = sync(pid)
    assert st.command_popup == nil
    assert st.menu_popup_id == :keymaps
  end

  test "esc closes the palette without running", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    type(pid, "/")
    key(pid, "esc")

    st = sync(pid)
    assert st.command_popup == nil
    assert st.menu_popup == nil
  end

  test "/help opens a popup listing every command", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    type(pid, "/help")
    key(pid, "enter")

    assert sync(pid).menu_popup_id == :help
    body = Enum.join(buffer(pid), "\n")
    assert body =~ "/sessions"
    assert body =~ "/export"
  end

  test "a typed /command is executed on send, not sent to the model", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    # type the command and send it with the real send chord (ctrl+enter)
    type(pid, "/keymaps")
    key(pid, "enter", ["ctrl"])

    st = sync(pid)
    # no user message was appended; the command ran
    assert st.transcript == []
    assert st.menu_popup_id == :keymaps
  end

  test "/new starts a fresh session", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    old = sync(pid).session_id
    type(pid, "/new")
    key(pid, "enter")

    # a new session id was mounted (the picker's `n` path)
    wait_until(fn -> sync(pid).session_id != old end)
    assert sync(pid).session_id != old
    assert sync(pid).command_popup == nil
  end

  test "/ mid-word stays plain text", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    type(pid, "and")
    type(pid, "/")
    assert sync(pid).command_popup == nil
    assert ExRatatui.textarea_get_value(sync(pid).textarea) == "and/"
  end
end
