defmodule CodingAgent.UI.Tui5bTest do
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.Tui

  defp start_app(opts \\ []) do
    start_supervised!({Tui, [name: nil, test_mode: {80, 24}, scope_root: File.cwd!()] ++ opts})
  end

  defp type(pid, code, mods \\ []), do: key(pid, code, mods)

  defp input_value(pid) do
    pid
    |> sync()
    |> Map.get(:textarea)
    |> ExRatatui.textarea_get_value()
  end

  describe "input area (5b)" do
    test "typing letters reaches the textarea" do
      pid = start_app()
      type(pid, "h")
      type(pid, "i")
      assert input_value(pid) == "hi"
    end

    test "enter inserts a newline (ADR 011 default)" do
      pid = start_app()
      type(pid, "a")
      type(pid, "enter")
      type(pid, "b")
      assert input_value(pid) == "a\nb"
    end

    test "alt-enter sends: transcript gets user line, buffer clears" do
      pid = start_app()
      type(pid, "h")
      type(pid, "i")
      type(pid, "enter", ["alt"])

      # send_input handles the key synchronously; the transcript line and
      # status flip happen inside the inject_event call. The Session.run
      # Task is a no-op under test_mode (tests are LLM-free).
      st = sync(pid)
      assert [{:user, "hi"}] = st.transcript
      assert input_value(pid) == ""
      assert st.status == :running
    end

    test "empty buffer alt-enter does not send" do
      pid = start_app()
      type(pid, "enter", ["alt"])
      assert sync(pid).transcript == []
    end

    test "bracketed paste lands in the buffer (paste-queue desync is gone)" do
      pid = start_app()

      :ok =
        ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Paste{
          content: "line one\nline two\nline three"
        })

      assert input_value(pid) == "line one\nline two\nline three"
    end

    # Regression (ADR 021, one authority): the raw event used to be
    # forwarded to the crate, whose own Emacs bindings disagreed with the
    # keymap. ctrl-j (declared :insert_newline) ran delete_line_by_head
    # and wiped the typed line; ctrl-u (declared :kill_line) ran undo.
    # The editor now performs the ACTION, so the keymap's claim holds.
    test "ctrl-j inserts a newline, it does NOT delete the line (ADR 021)" do
      pid = start_app()
      type(pid, "h")
      type(pid, "i")
      type(pid, "j", ["ctrl"])
      type(pid, "!")
      # a newline (the keymap's :insert_newline), not a wiped buffer
      assert input_value(pid) == "hi\n!"
    end

    test "ctrl-u kills the whole line (ADR 021)" do
      pid = start_app()
      for c <- String.graphemes("hello"), do: type(pid, c)
      type(pid, "u", ["ctrl"])
      assert input_value(pid) == ""
    end

    test "ctrl-k kills from the cursor to the line end (ADR 021)" do
      pid = start_app()
      for c <- String.graphemes("hello"), do: type(pid, c)
      # move the cursor home, then kill to end
      type(pid, "a", ["ctrl"])
      type(pid, "k", ["ctrl"])
      assert input_value(pid) == ""
    end

    test "ctrl-w deletes the word before the cursor (ADR 021)" do
      pid = start_app()
      for c <- String.graphemes("hello world"), do: type(pid, c)
      type(pid, "w", ["ctrl"])
      assert input_value(pid) == "hello "
    end

    test "an unbound ctrl chord is dropped, not forwarded raw (ADR 021)" do
      pid = start_app()
      type(pid, "a")
      type(pid, "z", ["ctrl"])
      # the crate would have executed its own ctrl-z binding; the
      # boundary drops an unowned key instead
      assert input_value(pid) == "a"
    end
  end

  describe "approval dialog (5b)" do
    # write_file became allow-by-policy (ADR 010 amendment 2026-09-15),
    # so these drive the pause explicitly through a repo-side policy
    # file — the dialog mechanics under test are unchanged.
    test "interrupted session renders pending calls; n rejects them" do
      root = Path.join(System.tmp_dir!(), "tui5b-#{System.unique_integer()}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      policy = write_ask_policy(root)

      sid = "tui5b-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: sid,
          scope_root: root,
          policy: policy,
          test_mode: true
        )

      :ok =
        CodingAgent.Core.Session.debug_gate(sid, [
          %{id: "c1", name: "write_file", arguments: %{"path" => "x.txt", "content" => "hi"}}
        ])

      pid = start_app(session_id: sid)
      assert sync(pid).status == :interrupted
      assert length(sync(pid).pending) == 1

      type(pid, "n")

      # decide runs in a task; status settles via the {:__decided__} reply
      wait_until(fn -> sync(pid).status == :idle end)
      assert sync(pid).pending == []
      refute File.exists?(Path.join(root, "x.txt"))
    end

    test "y approves and the tool executes" do
      root = Path.join(System.tmp_dir!(), "tui5b-#{System.unique_integer()}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      policy = write_ask_policy(root)

      sid = "tui5b-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: sid,
          scope_root: root,
          policy: policy,
          test_mode: true
        )

      :ok =
        CodingAgent.Core.Session.debug_gate(sid, [
          %{id: "c1", name: "write_file", arguments: %{"path" => "y.txt", "content" => "yes"}}
        ])

      pid = start_app(session_id: sid)
      assert length(sync(pid).pending) == 1

      type(pid, "y")

      wait_until(fn -> File.exists?(Path.join(root, "y.txt")) end)
      assert File.read!(Path.join(root, "y.txt")) == "yes"

      # status settles via the {:__decided__} reply (races the file write)
      wait_until(fn -> sync(pid).status == :idle end)
    end

    test "a refused decide does not lose the dialog" do
      root = Path.join(System.tmp_dir!(), "tui5b-#{System.unique_integer()}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      policy = write_ask_policy(root)

      sid = "tui5b-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: sid,
          scope_root: root,
          policy: policy,
          test_mode: true
        )

      :ok =
        CodingAgent.Core.Session.debug_gate(sid, [
          %{id: "c1", name: "write_file", arguments: %{"path" => "z.txt", "content" => "z"}}
        ])

      pid = start_app(session_id: sid)
      assert length(sync(pid).pending) == 1

      # the session stops waiting on its own (as after a race): the TUI's
      # optimistic close must NOT have discarded the dialog silently —
      # a refused decide re-syncs to the real state instead of erroring
      {:ok, _} = CodingAgent.Core.Session.decide(sid, [%{id: "c1", decision: :reject}])

      type(pid, "y")

      # converges to idle with no pending dialog and no crash; the file
      # was rejected by the first decide, so y did not write it
      wait_until(fn -> sync(pid).status == :idle and sync(pid).pending == [] end)
      refute File.exists?(Path.join(root, "z.txt"))
    end
  end

  # repo-side ask policy: the 2026-09-15 amendment made write_file
  # allow-by-default, and the approval dialog needs a pause to exist
  defp write_ask_policy(root) do
    toml_path = Path.join(root, "permissions.toml")

    File.write!(toml_path, """
    [permissions.write_file]
    "*" = "ask"
    """)

    CodingAgent.Core.Permissions.load(nil, toml_path)
  end
end
