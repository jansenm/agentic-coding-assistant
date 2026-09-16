defmodule CodingAgent.Core.Tools.ShellTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Tools.Shell

  @tmp_root System.tmp_dir!() |> Path.join("agent-shell-#{System.unique_integer()}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    tool = tool_for_scope()
    {:ok, tool: tool, scope_root: @tmp_root}
  end

  defp tool_for_scope do
    Shell.tool(%{root: @tmp_root})
  end

  describe "tool behavior" do
    test "captures stdout, stderr and the exit code", %{tool: tool} do
      {:ok, out} =
        ReqLLM.Tool.execute(tool, %{
          "command" => "echo hello; echo err >&2; exit 3"
        })

      assert out =~ "hello"
      assert out =~ "err"
      assert out =~ "exit 3"
    end

    test "runs with cwd pinned to the scope root", %{tool: tool} do
      {:ok, out} = ReqLLM.Tool.execute(tool, %{"command" => "pwd"})
      assert out =~ @tmp_root
    end

    test "times out, kills the command and returns partial output", %{tool: tool} do
      {:ok, out} =
        ReqLLM.Tool.execute(tool, %{
          "command" => "echo start; sleep 10; echo never-ever-ran",
          "timeout_secs" => 1
        })

      assert out =~ "TIMED OUT"
      assert out =~ "start"
      # the echoed command line contains the marker; the *output section*
      # must not — kill happened before the sleep ended
      [_header, output] = String.split(out, "--- output ---\n", parts: 2)
      assert output == "start\n"
    end

    test "hard cap refuses oversized timeouts", %{tool: tool} do
      {:error, msg} = ReqLLM.Tool.execute(tool, %{"command" => "x", "timeout_secs" => 5000})
      assert msg =~ "hard cap"
      assert msg =~ "split the work"
    end

    test "non-numeric timeouts are rejected", %{tool: tool} do
      # req_llm schema-validates before our callback sees it
      assert {:error, %ReqLLM.Error.Validation.Error{} = e} =
               ReqLLM.Tool.execute(tool, %{"command" => "x", "timeout_secs" => "banana"})

      assert Exception.message(e) =~ "timeout_secs"
    end

    test "empty or missing command is rejected", %{tool: tool} do
      assert {:error, _} = ReqLLM.Tool.execute(tool, %{"command" => ""})
      assert {:error, _} = ReqLLM.Tool.execute(tool, %{})
    end

    test "effective_timeout clamps and defaults" do
      assert {:ok, 300} = Shell.effective_timeout(%{})
      assert {:ok, 900} = Shell.effective_timeout(%{"timeout_secs" => 900})
      assert {:ok, 1} = Shell.effective_timeout(%{"timeout_secs" => 0})
      assert {:error, msg} = Shell.effective_timeout(%{"timeout_secs" => 9999})
      assert msg =~ "hard cap"
      assert {:ok, 300} = Shell.effective_timeout("not a map")
    end

    test "soft cap export matches the default" do
      assert Shell.soft_cap() == 300
    end
  end

  describe "gate integration (ADR 010, LLM-free)" do
    test "shell defaults to :ask (write_file is allow by the 2026-09-15 amendment)" do
      policy = Permissions.load(nil, nil)
      assert Permissions.effective(policy, "shell", "", "default") == :ask
      #    (write_file comparison for regression clarity)
      assert Permissions.effective(policy, "write_file", "", "default") == :allow
    end

    test "a shell call interrupts the session and executes on approval" do
      id = "shell-gate-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true
        )

      marker = Path.join(@tmp_root, "shell-ran-#{System.unique_integer()}")

      :ok =
        Session.debug_gate(id, [
          %{id: "s1", name: "shell", arguments: %{"command" => "touch #{marker}"}}
        ])

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted
      refute File.exists?(marker)

      {:ok, state2} = Session.decide(id, [%{id: "s1", decision: :approve}])
      assert state2.status == :idle
      assert File.exists?(marker)
    end

    test "a rejected shell call leaves no trace", do: reject_rejected_shell()
  end

  # -- Command blacklist (2026-09-15 ADR 010 amendment 2) ----------------------

  describe "command blacklist (2026-09-15 amendment 2)" do
    test "shell grep is denied with steering to the native grep tool", %{tool: tool} do
      {:ok, guidance} = Shell.blacklisted?(%{"command" => "grep -rn handle_call lib/"})
      assert guidance =~ "grep tool"
      assert guidance =~ "allow-by-policy"

      # direct tool execution is untouched — the gate is the policy point
      # (cwd is the tmp scope; make the file first)
      File.write!(Path.join(@tmp_root, "t.ex"), "def f, do: 1")
      assert {:ok, out} = ReqLLM.Tool.execute(tool, %{"command" => "grep -c def t.ex"})
      assert out =~ "exit 0"
    end

    test "the whole grep family is denied: rg, ag, ack, sg" do
      for prog <- ["rg", "ag", "ack", "sg"] do
        assert {:ok, guidance} = Shell.blacklisted?(%{"command" => "#{prog} pattern lib/"})
        assert guidance =~ "grep tool"
      end
    end

    test "absolute-path programs are recognized by basename" do
      assert {:ok, guidance} =
               Shell.blacklisted?(%{"command" => "/usr/bin/grep -n foo bar.ex"})

      assert guidance =~ "grep tool"
      assert {:ok, guidance} = Shell.blacklisted?(%{"command" => "/bin/grep foo bar"})
      assert guidance =~ "grep tool"
    end

    test "non-grep leading programs pass: sed, cat, ls, touch, mix" do
      # deliberately NOT covered yet (one-line follow-ups when wanted)
      assert :error = Shell.blacklisted?(%{"command" => "sed -n '1,5p' mix.exs"})
      assert :error = Shell.blacklisted?(%{"command" => "cat mix.exs"})
      assert :error = Shell.blacklisted?(%{"command" => "ls lib"})
      assert :error = Shell.blacklisted?(%{"command" => "mix test"})
      assert :error = Shell.blacklisted?(%{"command" => "echo hello"})
    end

    test "deliberately shallow: pipes and evader spellings are NOT caught" do
      assert :error = Shell.blacklisted?(%{"command" => "echo hi | grep hi"})
      assert :error = Shell.blacklisted?(%{"command" => "git grep handle_call"})
      assert :error = Shell.blacklisted?(%{"command" => "find . -name '*.ex' -exec grep x {} +"})
      # chained but LEADING: the first word is still grep — caught. The
      # shallow check is first-word only, in both directions.
      assert {:ok, _} = Shell.blacklisted?(%{"command" => "grep -q foo bar && touch marker"})
    end

    test "degenerate inputs are :error, not crashes" do
      assert :error = Shell.blacklisted?(%{})
      assert :error = Shell.blacklisted?(%{"command" => ""})
      assert :error = Shell.blacklisted?(%{"command" => nil})
      assert :error = Shell.blacklisted?("grep foo")
      assert :error = Shell.blacklisted?(nil)
    end

    test "gate denies blacklisted shell calls with NO keystroke (no interruption)" do
      id = "shell-bl-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true
        )

      log =
        capture_log(fn ->
          :ok =
            Session.debug_gate(id, [
              %{id: "g1", name: "shell", arguments: %{"command" => "grep -rn gate lib/"}}
            ])
        end)

      {:ok, state} = Session.state(id)
      # the point of the feature: no human pause — the call is answered
      # with the steering message in the same round
      refute state.status == :interrupted
      assert state.pending_tool_calls == []

      last = ReqLLM.Context.to_list(state.context) |> List.last()
      assert last.role == :tool
      assert text_of(last) =~ "please use the grep tool"
      assert log =~ "gate: shell command denied (blacklist)"
      assert log =~ "\"g1\""
    end

    test "gate denies only the blacklisted call in a mixed batch" do
      id = "shell-bl-mixed-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true
        )

      log =
        capture_log(fn ->
          :ok =
            Session.debug_gate(id, [
              %{id: "m1", name: "shell", arguments: %{"command" => "grep -rn gate lib/"}},
              %{
                id: "m2",
                name: "write_file",
                arguments: %{"path" => "bl-mixed.txt", "content" => "ok"}
              }
            ])
        end)

      {:ok, state} = Session.state(id)
      # m2 ran (allow class), m1 was answered without a pause
      assert File.read!(Path.join(@tmp_root, "bl-mixed.txt")) == "ok"
      refute state.status == :interrupted

      tool_msgs =
        state.context |> ReqLLM.Context.to_list() |> Enum.filter(&(&1.role == :tool))

      contents = Enum.map_join(tool_msgs, "\n", &text_of/1)
      assert contents =~ "please use the grep tool"
      assert log =~ "gate: shell command denied (blacklist)"
      assert log =~ "\"m1\""
    end

    test "non-blacklisted shell calls still interrupt (touch stays gated)" do
      id = "shell-bl-neg-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true
        )

      :ok =
        Session.debug_gate(id, [
          %{id: "n1", name: "shell", arguments: %{"command" => "touch bl-neg-marker"}}
        ])

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted
      refute File.exists?(Path.join(@tmp_root, "bl-neg-marker"))
    end
  end

  defp reject_rejected_shell do
    id = "shell-gate-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: id,
        scope_root: @tmp_root,
        test_mode: true
      )

    marker = Path.join(@tmp_root, "never-#{System.unique_integer()}")

    :ok =
      Session.debug_gate(id, [
        %{id: "s2", name: "shell", arguments: %{"command" => "touch #{marker}"}}
      ])

    {:ok, _} = Session.decide(id, [%{id: "s2", decision: :reject}])
    refute File.exists?(marker)

    {:ok, state} = Session.state(id)
    last = ReqLLM.Context.to_list(state.context) |> List.last()
    assert last.role == :tool
    assert text_of(last) =~ "rejected"
  end

  defp text_of(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t || ""
      _ -> ""
    end)
  end

  defp text_of(%ReqLLM.Message{content: c}) when is_binary(c), do: c
end
