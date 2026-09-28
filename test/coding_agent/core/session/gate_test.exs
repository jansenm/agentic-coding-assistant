defmodule CodingAgent.Core.Session.GateTest do
  use ExUnit.Case, async: false

  import CodingAgent.SandboxCase

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session.Gate
  alias CodingAgent.TestSandbox.Stub

  @tmp_root System.tmp_dir!()
            |> Path.join("session-gate-#{System.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@tmp_root)
    # ADR 030: a session requires a confining sandbox. The stub is the
    # suite's confining double; the gate's class-default behavior under it
    # is what these tests pin.
    put_sandbox(Stub)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  defp call(name, args), do: %{id: "c-#{System.unique_integer()}", name: name, arguments: args}

  defp policy, do: Permissions.load(nil, nil)

  describe "decision/4" do
    test "read-only tools are allow; shell is allow-by-default under confinement (ADR 030)" do
      assert Gate.decision(policy(), @tmp_root, "read_file", %{"path" => "a"}) == :allow
      assert Gate.decision(policy(), @tmp_root, "shell", %{"command" => "ls"}) == :allow
    end

    test "an escalation still asks even under confinement" do
      assert Gate.decision(policy(), @tmp_root, "shell", %{
               "command" => "curl x",
               "network" => true,
               "reason" => "install"
             }) == :ask
    end

    test "an explicit policy entry always wins over confinement" do
      path = Path.join(@tmp_root, "deny.toml")
      File.write!(path, "[permissions.shell]\n\"*\" = \"deny\"\n")
      policy = Permissions.load(nil, path)

      assert Gate.decision(policy, @tmp_root, "shell", %{"command" => "ls"}) == :deny
    end

    test "a path pattern matches relative to the scope root" do
      path = Path.join(@tmp_root, "ask-config.toml")
      File.write!(path, "[permissions.write_file]\n\"config/**\" = \"ask\"\n")
      policy = Permissions.load(nil, path)

      assert Gate.decision(policy, @tmp_root, "write_file", %{"path" => "config/a.ex"}) == :ask
      assert Gate.decision(policy, @tmp_root, "write_file", %{"path" => "lib/a.ex"}) == :allow
    end
  end

  describe "classify/4" do
    test "buckets allow/ask/deny" do
      path = Path.join(@tmp_root, "mixed.toml")
      File.write!(path, "[permissions.write_file]\n\"secret/**\" = \"deny\"\n")
      policy = Permissions.load(nil, path)

      calls = [
        call("read_file", %{"path" => "a"}),
        call("write_file", %{"path" => "secret/x"}),
        call("write_file", %{"path" => "a"}),
        call("shell", %{"command" => "ls"})
      ]

      plan = Gate.classify("s", policy, @tmp_root, calls)

      assert length(plan.auto) == 3
      assert length(plan.denied) == 1
      assert plan.pending == []
    end

    test "an explicit ask still parks" do
      path = Path.join(@tmp_root, "ask-shell.toml")
      File.write!(path, "[permissions.shell]\n\"*\" = \"ask\"\n")
      policy = Permissions.load(nil, path)

      plan = Gate.classify("s", policy, @tmp_root, [call("shell", %{"command" => "ls"})])

      assert length(plan.pending) == 1
    end

    test "a shell call duplicating a native tool is blacklisted, never pending" do
      plan = Gate.classify("s", policy(), @tmp_root, [call("shell", %{"command" => "grep x ."})])

      assert length(plan.blacklisted) == 1
      assert plan.pending == []
    end

    test "an escalation without a reason is its own bucket, never pending" do
      plan =
        Gate.classify("s", policy(), @tmp_root, [
          call("shell", %{"command" => "curl x", "network" => true})
        ])

      assert length(plan.no_reason) == 1
      assert plan.pending == []
    end
  end

  describe "result builders" do
    test "each refusal carries a model-readable message" do
      assert Gate.denied_result(call("write_file", %{"path" => "x"})).content =~ "denied"

      assert Gate.blacklist_result(call("shell", %{"command" => "grep x ."})).content =~
               "grep tool"

      escalated = call("shell", %{"command" => "curl x", "network" => true})
      assert Gate.no_reason_result(escalated).content =~ "reason"
    end
  end
end