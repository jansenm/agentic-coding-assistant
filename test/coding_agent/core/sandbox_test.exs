defmodule CodingAgent.Core.SandboxTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Sandbox
  alias CodingAgent.Core.Sandbox.None
  alias CodingAgent.TestSandbox.Stub
  alias CodingAgent.TestSandbox.Unavailable

  setup do
    Application.put_env(:coding_agent, :sandbox, None)
    :ok
  end

  describe "selection" do
    test "configured/0 returns what was asked for, even if unusable" do
      Application.put_env(:coding_agent, :sandbox, Unavailable)
      assert Sandbox.configured() == Unavailable
    end

    test "a confining implementation that is available is used" do
      Application.put_env(:coding_agent, :sandbox, Stub)
      assert Sandbox.impl() == Stub
    end

    test "a confining implementation that is unavailable falls back to None" do
      Application.put_env(:coding_agent, :sandbox, Unavailable)
      assert Sandbox.impl() == None
    end

    test "wrap/2 delegates to the effective implementation" do
      Application.put_env(:coding_agent, :sandbox, Stub)

      assert {:ok, "/bin/sh", ["-c", "echo hi"]} =
               Sandbox.wrap({:shell, "echo hi"}, %{root: "/repo"})
    end

    test "wrap/2 falls back to the no-op when the configured sandbox is unusable" do
      Application.put_env(:coding_agent, :sandbox, Unavailable)

      assert {:ok, "/bin/sh", ["-c", "echo hi"]} =
               Sandbox.wrap({:shell, "echo hi"}, %{root: "/repo"})
    end
  end

  describe "Sandbox.None" do
    test "is always available" do
      assert None.available?()
    end

    test "does not confine" do
      refute None.confines?()
      Application.put_env(:coding_agent, :sandbox, None)
      refute Sandbox.confines?()
    end

    test "wraps a shell command as /bin/sh -c, ignoring the profile" do
      assert {:ok, "/bin/sh", ["-c", "rm -rf /"]} =
               None.wrap({:shell, "rm -rf /"}, %{root: "/repo", network: true, git_write: true})
    end

    test "wraps an exec spec, resolving the executable" do
      assert {:ok, exe, ["status"]} = None.wrap({:exec, "git", ["status"]}, %{root: "/repo"})
      assert Path.type(exe) == :absolute
    end

    test "an unknown executable is an error, not a crash" do
      assert {:error, {:executable_not_found, _}} =
               None.wrap({:exec, "definitely-not-a-real-binary-xyz", ["x"]}, %{root: "/repo"})
    end

    test "id is :none" do
      assert None.id() == :none
    end
  end

  describe "confines?/0" do
    test "is true for a confining implementation that is available" do
      Application.put_env(:coding_agent, :sandbox, Stub)
      assert Sandbox.confines?()
    end

    test "is false when the confining implementation is unavailable" do
      Application.put_env(:coding_agent, :sandbox, Unavailable)
      refute Sandbox.confines?()
    end

    test "is false for the no-op" do
      Application.put_env(:coding_agent, :sandbox, None)
      refute Sandbox.confines?()
    end
  end

  describe "diagnose/0" do
    test "is :ok for the no-op" do
      Application.put_env(:coding_agent, :sandbox, None)
      assert Sandbox.diagnose() == :ok
    end

    test "surfaces the reason when a confining implementation cannot run" do
      Application.put_env(:coding_agent, :sandbox, Unavailable)
      assert {:error, reason} = Sandbox.diagnose()
      assert is_binary(reason)
    end

    test "is :ok when the confining implementation works" do
      Application.put_env(:coding_agent, :sandbox, Stub)
      assert Sandbox.diagnose() == :ok
    end

    test "reports an invalid configuration" do
      Application.put_env(:coding_agent, :sandbox, "not a module")
      assert {:error, reason} = Sandbox.diagnose()
      assert reason =~ "invalid"
    end
  end
end
