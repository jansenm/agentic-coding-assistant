defmodule CodingAgent.Core.Tools.ShellTest do
  use ExUnit.Case, async: false

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

    test "effective_timeout clamps and defaults", %{tool: tool} do
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
    test "shell defaults to :ask like write_file" do
      policy = Permissions.load(nil, nil)
      assert Permissions.effective(policy, "shell", "", "default") == :ask
      #    (write_file comparison for regression clarity)
      assert Permissions.effective(policy, "write_file", "", "default") == :ask
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
