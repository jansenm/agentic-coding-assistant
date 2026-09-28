defmodule CodingAgent.Core.SandboxTest do
  use ExUnit.Case, async: false

  import CodingAgent.SandboxCase

  alias CodingAgent.Core.Sandbox
  alias CodingAgent.Core.Sandbox.None
  alias CodingAgent.TestSandbox.Stub
  alias CodingAgent.TestSandbox.Unavailable

  describe "selection" do
    test "configured/0 returns what was asked for, even if unusable" do
      put_sandbox(Unavailable)
      assert Sandbox.configured() == Unavailable
    end

    test "a confining implementation that is available is used" do
      put_sandbox(Stub)
      assert Sandbox.impl() == Stub
      assert Sandbox.usable?()
    end

    # ADR 030: the silent fallback to None is gone. An unavailable
    # confining implementation yields nil, so callers must refuse.
    test "a confining implementation that is unavailable yields nil (no fallback)" do
      put_sandbox(Unavailable)
      assert Sandbox.impl() == nil
      refute Sandbox.usable?()
    end

    test "an explicit None is honored (the deliberate seam)" do
      put_sandbox(None)
      assert Sandbox.impl() == None
      assert Sandbox.usable?()
    end

    test "wrap/2 delegates to the effective implementation" do
      put_sandbox(Stub)

      assert {:ok, "/bin/sh", ["-c", "echo hi"]} =
               Sandbox.wrap({:shell, "echo hi"}, %{root: "/repo"})
    end

    # ADR 030: an unusable sandbox refuses — it never runs unconfined.
    test "wrap/2 refuses when the configured sandbox is unusable" do
      put_sandbox(Unavailable)

      assert {:error, {:sandbox_unavailable, message}} =
               Sandbox.wrap({:shell, "echo hi"}, %{root: "/repo"})

      assert message =~ "no usable sandbox"
    end
  end

  describe "Sandbox.None" do
    test "is always available" do
      assert None.available?()
    end

    test "does not confine" do
      refute None.confines?()
      put_sandbox(None)
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
      put_sandbox(Stub)
      assert Sandbox.confines?()
    end

    test "is false when the confining implementation is unavailable" do
      put_sandbox(Unavailable)
      refute Sandbox.confines?()
    end

    test "is false for the no-op" do
      put_sandbox(None)
      refute Sandbox.confines?()
    end
  end

  describe "diagnose/0" do
    test "is :ok for the no-op" do
      put_sandbox(None)
      assert Sandbox.diagnose() == :ok
    end

    test "surfaces the reason when a confining implementation cannot run" do
      put_sandbox(Unavailable)
      assert {:error, reason} = Sandbox.diagnose()
      assert is_binary(reason)
    end

    test "is :ok when the confining implementation works" do
      put_sandbox(Stub)
      assert Sandbox.diagnose() == :ok
    end

    test "reports an invalid configuration" do
      put_sandbox("not a module")
      assert {:error, reason} = Sandbox.diagnose()
      assert reason =~ "invalid"
    end
  end

  describe "refusal_message/0 (ADR 030)" do
    test "names the missing piece and the way out" do
      put_sandbox(Unavailable)
      message = Sandbox.refusal_message()

      assert message =~ "no usable sandbox"
      assert message =~ "unprivileged user namespaces"
      assert message =~ "Sandbox.None"
    end
  end
end
