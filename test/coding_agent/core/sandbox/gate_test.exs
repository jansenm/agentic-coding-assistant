defmodule CodingAgent.Core.Sandbox.GateTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Sandbox
  alias CodingAgent.Core.Session

  @tmp_root System.tmp_dir!() |> Path.join("agent-sandbox-gate-#{System.unique_integer([:positive])}")

  # A confining sandbox that still runs (wraps as /bin/sh) so the gate's
  # auto-run path can be exercised without a real bwrap. This is what
  # `Sandbox.Bwrap` looks like to the gate, minus the confinement.
  defmodule ConfiningShim do
    @behaviour Sandbox

    @impl true
    def id, do: :confining_shim

    @impl true
    def available?, do: true

    @impl true
    def confines?, do: true

    @impl true
    def wrap(command, _profile), do: {:ok, "/bin/sh", ["-c", command]}
  end

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    Application.delete_env(:coding_agent, :sandbox)
    on_exit(fn -> Application.delete_env(:coding_agent, :sandbox) end)
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

  describe "without confinement (Sandbox.None, the default)" do
    test "shell keeps the class-default :ask and interrupts" do
      id = "none-ask-#{System.unique_integer()}"
      start_session(id)

      :ok = gate(id, [%{id: "c1", name: "shell", arguments: %{"command" => "echo hi"}}])

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted
    end
  end

  describe "with confinement" do
    setup do
      Application.put_env(:coding_agent, :sandbox, ConfiningShim)
      :ok
    end

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
            arguments: %{"command" => "curl example.com", "network" => true}
          }
        ])

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted
    end

    test "a git_write escalation interrupts" do
      id = "conf-git-#{System.unique_integer()}"
      start_session(id)

      :ok =
        gate(id, [
          %{
            id: "c1",
            name: "shell",
            arguments: %{"command" => "./release.sh", "git_write" => true}
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
  defp text(content), do: inspect(content)
end
