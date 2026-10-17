defmodule CodingAgent.Core.SandboxTest do
  use ExUnit.Case, async: false

  import CodingAgent.SandboxCase

  alias CodingAgent.Core.Sandbox
  alias CodingAgent.Core.Sandbox.Bwrap
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
    end

    # ADR 030: the fallback to an unconfined run is gone. An unavailable
    # implementation yields nil, so callers must refuse.
    test "a confining implementation that is unavailable yields nil (no fallback)" do
      put_sandbox(Unavailable)
      assert Sandbox.impl() == nil
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

  describe "visible_path/2" do
    test "is the host path when the implementation does not remap /tmp" do
      # the test double does not bind the scratch over /tmp, so the optional
      # callback's identity default applies
      put_sandbox(Stub)
      host = "/var/tmp/scratch/checkpoint-index"

      assert Sandbox.visible_path(host, %{root: "/repo"}) == host
    end

    test "maps a scratch file to /tmp under bwrap (ADR 022)" do
      scratch = "/var/tmp/scratch-#{System.unique_integer([:positive])}"
      profile = %{root: "/repo", scratch: scratch}

      assert Bwrap.visible_path(Path.join(scratch, "checkpoint-index"), profile) ==
               "/tmp/checkpoint-index"

      assert Bwrap.visible_path(scratch, profile) == "/tmp"

      # a path outside the scratch is left alone
      assert Bwrap.visible_path("/etc/hosts", profile) == "/etc/hosts"
    end

    test "is the host path when bwrap has no session scratch (per-call tmpfs)" do
      assert Bwrap.visible_path("/etc/hosts", %{root: "/repo"}) == "/etc/hosts"
    end
  end

  describe "diagnose/0" do
    test "surfaces the reason when the implementation cannot run" do
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
    end
  end
end
