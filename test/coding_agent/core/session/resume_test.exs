# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.ResumeTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.State
  alias CodingAgent.Core.Session.Timing
  alias ReqLLM.Context

  @tmp_root System.tmp_dir!() |> Path.join("resume-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    CodingAgent.TestScope.declare_window!(@tmp_root)
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
      timing = Timing.restore(%{rounds: 3, llm_ms: 9_000, tool_ms: 3_000, turn_rounds: 1})

      s =
        state(
          usage: %{input_tokens: 42, output_tokens: 7, cost: nil},
          timing: timing,
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
      # N142: the token totals were durable, the round totals were not
      assert opts[:timing] == timing
      assert opts[:timing].rounds == 3
      assert opts[:compaction_warned] == true
      assert opts[:compaction_backoff] == 2
      assert opts[:status] == :interrupted
      assert opts[:pending_tool_calls] == [%{id: "c1"}]
      assert opts[:pending_round_results] == [%{id: "c0"}]
    end

    test "carries the prompt override (ADR 024)" do
      # Without this, a model switch after resume would recompose from the
      # model file and silently drop the caller's custom system prompt.
      opts = Session.resume_opts(state(prompt_override: "MY-OVERRIDE"))
      assert opts[:system_prompt] == "MY-OVERRIDE"
    end

    test "carries the todo list (ADR 031)" do
      todos = [%{"content" => "Ship it", "status" => "in_progress"}]
      assert Session.resume_opts(state(todos: todos))[:todos] == todos
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

  describe "the persisted model (resume semantics)" do
    setup do
      # this suite persists; isolate the store (one SQLite DB, ADR 020)
      prev = Application.get_env(:coding_agent, :store_path)
      Application.put_env(:coding_agent, :store_path, Path.join(@tmp_root, "store.db"))
      on_exit(fn -> if prev, do: Application.put_env(:coding_agent, :store_path, prev) end)
      :ok
    end

    test "an idle model switch is persisted (survives a resume)" do
      # Regression, found live: switching the model between turns showed
      # the new model in the menu but was NOT persisted, so quitting
      # before the next turn resumed the OLD model ("it always resets to
      # glm"). set_agent/2 persisted at idle; set_model/2 did not.
      id = "resume-model-#{System.unique_integer([:positive])}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true,
          model: "ollama:old-model"
        )

      # write the row first, so the assertion below is about the model
      # CHANGING (not about a row appearing)
      {:ok, initial} = Session.state(id)
      :ok = CodingAgent.Core.Session.Store.save(initial)
      assert {:ok, %{model: "ollama:old-model"}} = CodingAgent.Core.Session.Store.load(id)

      :ok = Session.set_model(id, "ollama:new-model")

      # persisted immediately, not only after the next turn
      assert {:ok, stored} = CodingAgent.Core.Session.Store.load(id)
      assert stored.model == "ollama:new-model"

      # and a resume of that snapshot keeps it
      assert {:ok, _} = Session.resume(stored)
      assert {:ok, live} = Session.state(id)
      assert live.model == "ollama:new-model"
    end

    # N142: `usage` survived a resume and `timing` did not, so `/stats`
    # reported the session's tokens over the CURRENT process's rounds. The
    # unit test above pins `resume_opts/2`; this one walks the store, the
    # load and the resume, because the bug was in the path between them.
    test "the round totals survive a resume, exactly like the token totals" do
      id = "resume-timing-#{System.unique_integer([:positive])}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true,
          model: "ollama:test-model"
        )

      {:ok, live} = Session.state(id)

      timing =
        live.timing
        |> Timing.start()
        |> Timing.finish_llm(4_200)
        |> then(fn t -> t |> Timing.finish_tools(800) |> elem(0) end)

      snapshot = %{live | timing: timing, usage: %{input_tokens: 42_000, output_tokens: 700}}
      # the live process would answer `state/1` with its own (fresh) timing
      # and ignore the snapshot; retire it first, the way quitting the TUI
      # does, so the assertions below are about the RESUME path
      :ok = Session.stop(id)
      :ok = CodingAgent.Core.Session.Store.save(snapshot)

      assert {:ok, stored} = CodingAgent.Core.Session.Store.load(id)
      assert stored.timing.rounds == 1

      assert {:ok, _} = Session.resume(stored)
      assert {:ok, again} = Session.state(id)

      assert again.timing.rounds == 1
      assert again.timing.llm_ms == 4_200
      assert again.timing.tool_ms == 800
      # the per-turn counters are not a session total: they reset at the
      # next `begin_turn/1`, and the in-flight stamp never survives
      assert again.timing.started_at == nil
      assert again.usage.input_tokens == 42_000
    end
  end
end
