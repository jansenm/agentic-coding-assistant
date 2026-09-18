defmodule CodingAgent.Core.Session.ResumeTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.State
  alias ReqLLM.Context

  @tmp_root System.tmp_dir!() |> Path.join("resume-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  defp state(overrides \\ []) do
    base = %{
      id: "resume-#{System.unique_integer([:positive])}",
      context: Context.new(),
      model: "ollama:test-model",
      status: :idle,
      scope_root: @tmp_root
    }

    struct!(State, Map.merge(base, Map.new(overrides)))
  end

  describe "resume_opts/2" do
    test "carries the persisted fields a fresh session would otherwise lose" do
      s =
        state(
          usage: %{input_tokens: 42, output_tokens: 7, cost: nil},
          compaction_warned: true,
          compaction_backoff: 2,
          status: :interrupted,
          pending_tool_calls: [%{id: "c1"}],
          pending_round_calls: [%{id: "c1"}],
          pending_round_results: [%{id: "c0"}]
        )

      opts = Session.resume_opts(s)

      assert opts[:id] == s.id
      assert opts[:usage] == s.usage
      assert opts[:compaction_warned] == true
      assert opts[:compaction_backoff] == 2
      assert opts[:status] == :interrupted
      assert opts[:pending_tool_calls] == [%{id: "c1"}]
      assert opts[:pending_round_results] == [%{id: "c0"}]
    end

    test "restores the BASE policy, not the agent-narrowed one" do
      base = Permissions.load(nil, nil)
      narrowed = Permissions.apply_agent(base, %{disallowed_tools: ["shell"], tools: nil})

      s = state(policy: narrowed, base_policy: base, agent: nil)

      assert Session.resume_opts(s)[:policy] == base
    end

    test "restores a persisted agent only when its definition still exists" do
      agent = %CodingAgent.Core.Agent{
        name: "build",
        prompt: "p",
        source: "test",
        mode: :primary
      }

      assert Session.resume_opts(state(agent: agent))[:agent] == "build"

      gone = %{agent | name: "deleted-forever"}
      assert Session.resume_opts(state(agent: gone))[:agent] == nil
    end

    test "overrides win (the CLI's explicit --agent)" do
      s = state(agent: nil)
      assert Session.resume_opts(s, agent: "plan")[:agent] == "plan"
    end
  end

  describe "resume/2" do
    test "starts a live session from a persisted state" do
      s = state()

      assert {:ok, pid} = Session.resume(s)
      assert is_pid(pid)

      assert {:ok, live} = Session.state(s.id)
      assert live.id == s.id
      assert live.model == "ollama:test-model"
    end
  end
end
