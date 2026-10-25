defmodule CodingAgent.UI.TuiCommandsTest do
  @moduledoc """
  The `/` command palette and typed-command execution (ADR 034).
  """
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.Core.Session.Timing
  alias CodingAgent.Core.Session.Usage
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
    # prefix-matches `model`, and `catalog`'s summary says "model catalog"
    assert Enum.map(popup.matches, & &1.name) == ["model", "catalog"]
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

  test "/stats opens a snapshot of the session's time and spend", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    type(pid, "/stats")
    key(pid, "enter")

    assert sync(pid).menu_popup_id == :stats

    body = Enum.join(buffer(pid), "\n")
    assert body =~ "rounds"
    assert body =~ "llm"
    assert body =~ "tokens"
  end

  test "a finished round shows in the sidebar as llm + tools (I1)", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    round = %{round: 1, llm_ms: 4_200, tool_ms: 600}
    agent(pid, {:timing, %Timing{rounds: 1, llm_ms: 4_200, tool_ms: 600, last: round}})
    fire(pid, :__resize_poll__)

    body = Enum.join(buffer(pid), "\n")
    assert body =~ "last round"
    assert body =~ "4.2 s + 600 ms"
  end

  test "/stats reads the TUI's mirror, so a running turn is not zeros", %{root: root} do
    # A turn runs in a worker: the session PROCESS still holds the state the
    # turn started from, so `Session.state/1` reported a running turn's
    # rounds and tokens as zero until it returned. `/stats` must read the
    # events the sidebar already mirrors.
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    round = %{round: 7, llm_ms: 4_200, tool_ms: 600}

    agent(pid, {
      :timing,
      %Timing{
        rounds: 7,
        llm_ms: 63_000,
        tool_ms: 12_000,
        turn_rounds: 2,
        turn_llm_ms: 9_000,
        turn_tool_ms: 4_000,
        last: round
      }
    })

    agent(pid, {
      :usage_updated,
      %Usage{input_tokens: 121_345, output_tokens: 900, cached_tokens: 96_000}
    })

    type(pid, "/stats")
    key(pid, "enter")

    body = Enum.join(buffer(pid), "\n")
    assert body =~ "7 calls"
    assert body =~ "1m 03s"
    assert body =~ "121.3k in"
    assert body =~ "96.0k cached"
    assert body =~ "2 calls"
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

  test "/ after text stays plain text (a path, not a command)", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    type(pid, "run /bin/ls")
    assert sync(pid).command_popup == nil
    assert ExRatatui.textarea_get_value(sync(pid).textarea) == "run /bin/ls"
  end

  test "a slash with text after the cursor is an edit, not a command (review N6)",
       %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    type(pid, "abc")
    # move the cursor to column 0; the composer is not empty
    key(pid, "left")
    key(pid, "left")
    key(pid, "left")

    type(pid, "/")
    assert sync(pid).command_popup == nil
    # the slash lands at the cursor, the text is not shifted by a write-back
    assert ExRatatui.textarea_get_value(sync(pid).textarea) == "/abc"
  end

  test "esc returns a typed /query to the composer (a spilled path stays a message)",
       %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    type(pid, "/tmp/spill/grep-1")
    assert sync(pid).command_popup != nil

    key(pid, "esc")
    st = sync(pid)
    assert st.command_popup == nil
    assert ExRatatui.textarea_get_value(st.textarea) == "/tmp/spill/grep-1"
  end

  test "enter with no matching command returns the query, not nothing", %{root: root} do
    pid = start_tui(root)
    fire(pid, :__resize_poll__)

    type(pid, "/notacommand")
    assert sync(pid).command_popup.matches == []

    key(pid, "enter")
    st = sync(pid)
    assert st.command_popup == nil
    assert ExRatatui.textarea_get_value(st.textarea) == "/notacommand"
  end
end
