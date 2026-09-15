defmodule CodingAgent.UI.Tui5bTest do
  use ExUnit.Case, async: false

  alias CodingAgent.UI.Tui
  alias ExRatatui.Runtime

  defp start_app(opts \\ []) do
    pid =
      start_supervised!({Tui, [name: nil, test_mode: {80, 24}, scope_root: File.cwd!()] ++ opts})

    Process.sleep(50)
    pid
  end

  defp type(pid, code, mods \\ []) do
    :ok =
      Runtime.inject_event(pid, %ExRatatui.Event.Key{code: code, kind: "press", modifiers: mods})
  end

  defp input_value(pid) do
    pid
    |> :sys.get_state()
    |> Map.get(:user_state)
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

      wait_until(fn -> length(state(pid).transcript) == 1 end)
      assert [{:user, "hi"}] = state(pid).transcript
      assert input_value(pid) == ""
      assert state(pid).status == :running
    end

    test "empty buffer alt-enter does not send" do
      pid = start_app()
      type(pid, "enter", ["alt"])
      Process.sleep(100)
      assert state(pid).transcript == []
    end

    test "bracketed paste lands in the buffer (paste-queue desync is gone)" do
      pid = start_app()

      :ok =
        Runtime.inject_event(pid, %ExRatatui.Event.Paste{
          content: "line one\nline two\nline three"
        })

      assert input_value(pid) == "line one\nline two\nline three"
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
      assert state(pid).status == :interrupted
      assert length(state(pid).pending) == 1

      type(pid, "n")

      # decide runs in a task; status settles via the {:__decided__} reply
      wait_until(fn -> state(pid).status == :idle end)
      assert state(pid).pending == []
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
      assert length(state(pid).pending) == 1

      type(pid, "y")

      wait_until(fn -> File.exists?(Path.join(root, "y.txt")) end)
      assert File.read!(Path.join(root, "y.txt")) == "yes"

      # status settles via the {:__decided__} reply (races the file write)
      wait_until(fn -> state(pid).status == :idle end)
    end
  end

  defp state(pid), do: :sys.get_state(pid) |> Map.get(:user_state)

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

  # generous ceiling: under the full suite's parallelism the alt-enter
  # round-trip (inject → TUI → session spawn → run_turn → broadcast)
  # can blow past 1s — the tui_5b flake (1-in-3 runs) was a timeout,
  # not a logic break. Same cure as the live-gate flake: fewer, longer
  # polls.
  defp wait_until(fun, tries \\ 150) do
    if fun.() do
      :ok
    else
      if tries <= 0, do: flunk("wait_until timed out")

      Process.sleep(50)
      wait_until(fun, tries - 1)
    end
  end
end
