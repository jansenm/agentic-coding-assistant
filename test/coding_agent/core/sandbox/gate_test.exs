defmodule CodingAgent.Core.Sandbox.GateTest do
  use ExUnit.Case, async: false

  import CodingAgent.SandboxCase
  import ExUnit.CaptureLog

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.TestSandbox.Stub

  @tmp_root System.tmp_dir!()
            |> Path.join("agent-sandbox-gate-#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    # the suite default (config/test.exs): confining test double — a
    # session requires confinement (ADR 030)
    put_sandbox(Stub)
    :ok
  end

  defp start_session(id) do
    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: id,
        scope_root: @tmp_root,
        test_mode: true
      )
  end

  defp gate(id, calls), do: Session.debug_gate(id, calls)

  describe "without confinement (ADR 030: no session starts)" do
    test "a session refuses to start under Sandbox.None" do
      put_sandbox(CodingAgent.Core.Sandbox.None)

      assert {:error, {%RuntimeError{message: message}, _stack}} =
               CodingAgent.Core.Session.Supervisor.start_session(
                 id: "none-refuse-#{System.unique_integer()}",
                 scope_root: @tmp_root,
                 test_mode: true
               )

      assert message =~ "no usable sandbox"
      assert message =~ "Sandbox.None"
    end
  end

  describe "with confinement" do
    test "shell is allow-by-default and does not interrupt" do
      id = "conf-allow-#{System.unique_integer()}"
      start_session(id)

      marker = Path.join(@tmp_root, "ran-#{System.unique_integer()}")

      :ok =
        gate(id, [
          %{id: "c1", name: "shell", arguments: %{"command" => "touch #{marker}"}}
        ])

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      assert File.exists?(marker)
    end

    test "a network escalation interrupts" do
      id = "conf-net-#{System.unique_integer()}"
      start_session(id)

      :ok =
        gate(id, [
          %{
            id: "c1",
            name: "shell",
            arguments: %{
              "command" => "curl example.com",
              "network" => true,
              "reason" => "install the missing dependency"
            }
          }
        ])

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted
    end

    test "an escalation without a reason is refused without a pause" do
      id = "conf-net-noreason-#{System.unique_integer()}"
      start_session(id)

      log =
        capture_log(fn ->
          :ok =
            gate(id, [
              %{
                id: "c1",
                name: "shell",
                arguments: %{"command" => "curl example.com", "network" => true}
              }
            ])
        end)

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      last = ReqLLM.Context.to_list(state.context) |> List.last()
      assert last.role == :tool
      assert last.content |> text() =~ "reason"
      assert log =~ "escalation without reason"
    end

    test "a git_write escalation interrupts" do
      id = "conf-git-#{System.unique_integer()}"
      start_session(id)

      :ok =
        gate(id, [
          %{
            id: "c1",
            name: "shell",
            arguments: %{
              "command" => "./release.sh",
              "git_write" => true,
              "reason" => "release script commits the version bump"
            }
          }
        ])

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted
    end

    test "an explicit policy deny still wins over confinement" do
      id = "conf-deny-#{System.unique_integer()}"
      toml = "[permissions.shell]\n\"*\" = \"deny\"\n"
      path = Path.join(@tmp_root, "deny-shell.toml")
      File.write!(path, toml)
      policy = Permissions.load(nil, path)

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true,
          policy: policy
        )

      :ok = gate(id, [%{id: "c1", name: "shell", arguments: %{"command" => "echo hi"}}])

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      last = ReqLLM.Context.to_list(state.context) |> List.last()
      assert last.role == :tool
      assert last.content |> text() =~ "denied"
    end

    test "an explicit policy allow still runs even with an escalation" do
      id = "conf-allow-explicit-#{System.unique_integer()}"
      toml = "[permissions.shell]\n\"*\" = \"allow\"\n"
      path = Path.join(@tmp_root, "allow-shell.toml")
      File.write!(path, toml)
      policy = Permissions.load(nil, path)

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true,
          policy: policy
        )

      :ok =
        gate(id, [
          %{id: "c1", name: "shell", arguments: %{"command" => "echo hi", "network" => true}}
        ])

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
    end
  end

  defp text(content) when is_binary(content), do: content

  defp text(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t || ""
      _ -> ""
    end)
  end

  defp text(content), do: inspect(content)
end
