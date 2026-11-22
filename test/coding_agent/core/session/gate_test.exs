# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.GateTest do
  use ExUnit.Case, async: false

  import CodingAgent.SandboxCase
  import ExUnit.CaptureLog

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session.Gate
  alias CodingAgent.Core.Tools.Shell
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

    test "a two-path call is denied when EITHER end matches (move_file)" do
      path = Path.join(@tmp_root, "move-deny.toml")
      File.write!(path, "[permissions.move_file]\n\"lib/**\" = \"deny\"\n")
      policy = Permissions.load(nil, path)

      # `to` inside lib/ is denied even though `from` is not — without
      # evaluating both, the lookup would see no `path` and fall back to :allow
      assert Gate.decision(policy, @tmp_root, "move_file", %{
               "from" => "scratch/a.ex",
               "to" => "lib/a.ex"
             }) == :deny

      assert Gate.decision(policy, @tmp_root, "move_file", %{
               "from" => "lib/a.ex",
               "to" => "scratch/b.ex"
             }) == :deny

      assert Gate.decision(policy, @tmp_root, "move_file", %{
               "from" => "scratch/a.ex",
               "to" => "scratch/b.ex"
             }) == :allow
    end

    test "a two-path call is denied when EITHER end matches (move_region)" do
      path = Path.join(@tmp_root, "region-deny.toml")
      File.write!(path, "[permissions.move_region]\n\"lib/**\" = \"deny\"\n")
      policy = Permissions.load(nil, path)

      # `move_region` names its ends `from_path`/`to_path`, not
      # `from`/`to`: the lookup must read those names or it sees no path
      # and falls back to the class default (review N134).
      assert Gate.decision(policy, @tmp_root, "move_region", %{
               "from_path" => "scratch/a.ex",
               "to_path" => "lib/a.ex"
             }) == :deny

      assert Gate.decision(policy, @tmp_root, "move_region", %{
               "from_path" => "lib/a.ex",
               "to_path" => "scratch/b.ex"
             }) == :deny

      assert Gate.decision(policy, @tmp_root, "move_region", %{
               "from_path" => "scratch/a.ex",
               "to_path" => "scratch/b.ex"
             }) == :allow
    end

    test "a declared path argument that is absent fails closed, it is not 'no path'" do
      log =
        capture_log(fn ->
          assert Gate.decision(policy(), @tmp_root, "read_file", %{}) == :deny
          assert Gate.decision(policy(), @tmp_root, "move_file", %{"from" => "a.txt"}) == :deny

          assert Gate.decision(policy(), @tmp_root, "write_file", %{"path" => ""}) == :deny
        end)

      assert log =~ "missing_path_argument"
      assert log =~ "invalid_path_argument"
    end

    test "an unknown tool is refused instead of falling back to the class default" do
      log =
        capture_log(fn ->
          assert Gate.decision(policy(), @tmp_root, "not_a_tool", %{}) == :deny
        end)

      assert log =~ "unknown_tool"
    end

    test "an optional path argument uses the default the tool declares" do
      assert Gate.decision(policy(), @tmp_root, "list_dir", %{}) == :allow
      assert Gate.decision(policy(), @tmp_root, "grep", %{"pattern" => "x"}) == :allow
    end

    test "a tool that declares no path keeps the no-path lookup" do
      assert Gate.decision(policy(), @tmp_root, "shell", %{"command" => "ls"}) == :allow

      assert Gate.decision(policy(), @tmp_root, "webfetch", %{"url" => "https://example.com"}) ==
               :ask
    end

    test "the capability block asks the no-call lookup, not a fabricated call" do
      assert Gate.capability_decision(policy(), "read_file") == :allow
      assert Gate.capability_decision(policy(), "webfetch") == :ask
    end

    test "delete_file, move_file and move_region are allow-by-class under confinement (ADR 045)" do
      assert Gate.decision(policy(), @tmp_root, "delete_file", %{"path" => "a.txt"}) == :allow

      assert Gate.decision(policy(), @tmp_root, "move_file", %{
               "from" => "a.txt",
               "to" => "b.txt"
             }) == :allow

      assert Gate.decision(policy(), @tmp_root, "move_region", %{
               "from_path" => "a.txt",
               "to_path" => "b.txt"
             }) == :allow
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

    test "a shell call duplicating a native tool is redirected, never pending" do
      plan = Gate.classify("s", policy(), @tmp_root, [call("shell", %{"command" => "grep x ."})])

      assert length(plan.redirected) == 1
      assert plan.pending == []
    end

    test "a stated escalation outranks the redirect: the hint is advice, never a wall" do
      # `grep -rn x lib` matches the redirect on its first word,
      # `bash -c 'grep …'` does not. If the hint were final, the honest
      # spelling would be steered away while the wrapped one reached the
      # gate — so a stated, reasoned escalation goes to the human instead.
      escalated =
        call("shell", %{
          "command" => "grep -rn x lib",
          "network" => true,
          "reason" => "the search needs a remote index"
        })

      assert Shell.redirect(escalated.arguments) == :ok

      plan = Gate.classify("s", policy(), @tmp_root, [escalated])

      assert plan.redirected == []
      assert length(plan.pending) == 1
    end

    test "a git network escalation asks, and a git call without one does not" do
      ask =
        call("git", %{
          "args" => ["fetch", "origin"],
          "network" => true,
          "reason" => "fetch the upstream tags"
        })

      plan = Gate.classify("s", policy(), @tmp_root, [ask])
      assert length(plan.pending) == 1
      assert plan.redirected == []

      # the same call without the escalation: allow-by-default, like git
      # always was (only the network grant re-enables the prompt)
      plain = call("git", %{"args" => ["fetch", "origin"]})
      plan = Gate.classify("s", policy(), @tmp_root, [plain])
      assert length(plan.auto) == 1

      # `change_vcs` is granted unconditionally to this tool, so stating it
      # is not an escalation the tool offers and must not cost a keystroke
      write = call("git", %{"args" => ["commit", "-am", "x"], "change_vcs" => true})
      plan = Gate.classify("s", policy(), @tmp_root, [write])
      assert length(plan.auto) == 1
      assert plan.pending == []
    end

    test "a git network escalation without a reason is refused, naming the git call" do
      plan =
        Gate.classify("s", policy(), @tmp_root, [
          call("git", %{"args" => ["fetch", "origin"], "network" => true})
        ])

      assert length(plan.no_reason) == 1

      call = hd(plan.no_reason)
      result = Gate.no_reason_result(call)
      assert result.name == "git"
      assert result.content =~ "reason"
      assert result.content =~ "network"
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

      assert Gate.redirect_result(call("shell", %{"command" => "grep x ."})).content =~
               "grep tool"

      escalated = call("shell", %{"command" => "curl x", "network" => true})
      assert Gate.no_reason_result(escalated).content =~ "reason"
    end
  end
end
