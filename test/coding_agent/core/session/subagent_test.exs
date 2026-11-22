# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.SubagentTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.Subagent

  @tmp_root System.tmp_dir!() |> Path.join("agent-subagent-#{System.unique_integer()}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    # a fresh agent dir per test: one subagent definition to delegate to
    root = Path.join(@tmp_root, "scope-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".coding-agent/agents"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write_agent(root, name, body, frontmatter \\ "") do
    File.write!(
      Path.join(root, ".coding-agent/agents/#{name}.md"),
      "---\nname: #{name}\ndescription: test agent\n#{frontmatter}---\n#{body}\n"
    )
  end

  # The loaded definition by name — what a runtime start passes in place
  # of a name (its own delegation rule already ran).
  defp definition(root, name) do
    {:ok, definitions} = CodingAgent.Core.Config.agents(root)
    {Enum.find(definitions, &(&1.name == name)), definitions}
  end

  defp start_parent(id, root, opts) do
    {:ok, _} =
      Session.Supervisor.start_session(
        Keyword.merge(
          [
            id: id,
            scope_root: root,
            policy: Permissions.load(nil, nil),
            test_mode: true,
            agent: "build"
          ],
          opts
        )
      )
  end

  # A child runner: it mimics a streamed turn by completing with a final
  # answer, so the parent can extract the summary through the real path.
  defp child_runner(answer) do
    fn state ->
      state = Session.debug_complete_turn(state, answer, [{:assistant, answer}])
      {state, {:ok, state}}
    end
  end

  defp task_call(id, type, prompt) do
    %{
      id: id,
      name: "task",
      arguments: %{"description" => "d", "prompt" => prompt, "subagent_type" => type}
    }
  end

  describe "the task tool (ADR 017/018)" do
    test "is registered and named" do
      assert CodingAgent.Core.Tools.Task.name() == "task"

      names =
        CodingAgent.Core.Tools.all(%{root: @tmp_root}) |> Enum.map(& &1.name)

      assert "task" in names
    end

    test "an interactive primary's round delegates and returns the child summary", %{root: root} do
      write_agent(root, "explorer", "You explore the codebase.")
      id = "sub-run-#{System.unique_integer([:positive])}"

      start_parent(id, root,
        interactive: true,
        subagent_runner: child_runner("SUMMARY: found 3 call sites in lib/")
      )

      :ok = Session.debug_gate(id, [task_call("t1", "explorer", "find the call sites")])

      {:ok, state} = Session.state(id)

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "SUMMARY: found 3 call sites"
    end

    test "the child is ephemeral: it is not listed as a persisted session", %{root: root} do
      write_agent(root, "explorer", "You explore.")
      id = "sub-ephemeral-#{System.unique_integer([:positive])}"

      start_parent(id, root,
        interactive: true,
        subagent_runner: child_runner("a summary")
      )

      :ok = Session.debug_gate(id, [task_call("t1", "explorer", "go")])

      ids = CodingAgent.Core.Session.Store.list_in(root) |> Enum.map(& &1.id)
      refute Enum.any?(ids, &String.starts_with?(&1, "subagent-"))
    end

    test "an unknown subagent_type is a fixable error, not a crash", %{root: root} do
      id = "sub-bad-type-#{System.unique_integer([:positive])}"
      start_parent(id, root, interactive: true)
      :ok = Session.debug_gate(id, [task_call("t1", "nope", "go")])

      {:ok, state} = Session.state(id)

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "unknown subagent"
      refute state.status == :error
    end

    test "a primary agent cannot be delegated to", %{root: root} do
      # `build` is a primary (shipped); delegating to it is refused.
      id = "sub-primary-#{System.unique_integer([:positive])}"
      start_parent(id, root, interactive: true)
      :ok = Session.debug_gate(id, [task_call("t1", "build", "go")])

      {:ok, state} = Session.state(id)

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "primary"
    end

    test "an internal agent cannot be delegated to either", %{root: root} do
      # `compaction` is `:internal` (shipped): the runtime drives it, no
      # delegation. `find_definition/2` reads `Agent.delegatable?/1`, so
      # this is refused for the mode, not just for being non-primary.
      id = "sub-internal-#{System.unique_integer([:positive])}"
      start_parent(id, root, interactive: true)
      :ok = Session.debug_gate(id, [task_call("t1", "compaction", "go")])

      {:ok, state} = Session.state(id)

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "internal"
      assert text =~ "not delegatable"
    end

    test "a failed child surfaces as an error result, not a failed parent turn", %{root: root} do
      write_agent(root, "grumpy", "You fail.")
      id = "sub-child-fail-#{System.unique_integer([:positive])}"

      failing = fn state -> {state, {:error, :boom}} end

      start_parent(id, root, interactive: true, subagent_runner: failing)
      :ok = Session.debug_gate(id, [task_call("t1", "grumpy", "go")])

      {:ok, state} = Session.state(id)
      refute state.status == :error

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "subagent failed"
    end

    # F1: `Subagent.run/2` is documented to always return a result, but a
    # raise INSIDE it (the seam runs third-party-adjacent code: agent
    # loading, summarising a child state) must still become an error
    # result — and must still close the child's lifecycle. Linked
    # `Task.async_stream` killed the delegating caller before the
    # `{:exit, _}` branch could ever run; a skipped finish event left the
    # TUI tab "running" forever.
    test "a raise inside Subagent.run/2 becomes an error result, not a dead parent", %{root: root} do
      write_agent(root, "grumpy", "You fail.")
      id = "sub-child-raise-#{System.unique_integer([:positive])}"

      # the runner completes the child turn, but with a context that
      # `summarize/1` cannot read: `ReqLLM.Context.to_list/1` raises.
      corrupting = fn state -> {state, {:ok, %{state | context: :garbage}}} end

      start_parent(id, root, interactive: true, subagent_runner: corrupting)
      :ok = Session.subscribe(id)
      :ok = Session.debug_gate(id, [task_call("t1", "grumpy", "go")])

      {:ok, state} = Session.state(id)
      refute state.status == :error

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "subagent crashed"

      # the lifecycle closed: the finish event was published (the tab
      # would otherwise stay "running"), and the child session was
      # retired by cleanup/1 (no longer registered)
      events = drain_events()
      assert Enum.any?(events, &match?({:subagent_finished, _, :error}, &1))

      child_id = child_id_of(events)
      assert Registry.lookup(CodingAgent.Registry, {:session, child_id}) == []
    end

    test "a task call alongside a gated sibling defers the sibling and still runs the child",
         %{root: root} do
      write_agent(root, "explorer", "x", "mode: subagent\n")
      toml = Path.join(root, "permissions.toml")
      File.write!(toml, "[permissions.write_file]\n\"*\" = \"ask\"\n")

      id = "sub-mixed-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Session.Supervisor.start_session(
          id: id,
          scope_root: root,
          policy: Permissions.load(nil, toml),
          test_mode: true,
          interactive: true,
          subagent_runner: child_runner("mixed summary")
        )

      write = %{
        id: "w1",
        name: "write_file",
        arguments: %{"path" => "x.txt", "content" => "x"}
      }

      :ok = Session.debug_gate(id, [task_call("t1", "explorer", "go"), write])

      # the sibling parked, and the task's summary is carried across the pause
      {:ok, state} = Session.state(id)
      assert state.status == :interrupted

      held = Enum.map(state.pending_round_results, & &1.id)
      assert "t1" in held
    end
  end

  describe "depth 1 (ADR 017)" do
    test "the delegatable list excludes primaries and internal", %{root: root} do
      write_agent(root, "explorer", "x", "mode: subagent\n")
      write_agent(root, "reviewer", "y", "mode: all\n")
      write_agent(root, "boss", "z", "mode: primary\n")
      write_agent(root, "driver", "z", "mode: internal\n")

      {:ok, definitions} = CodingAgent.Core.Config.agents(root)
      names = Subagent.delegatable(definitions) |> Enum.map(& &1.name)

      assert "explorer" in names
      assert "reviewer" in names
      refute "boss" in names
      refute "driver" in names
    end

    test "a depth-1 parent refuses to delegate further", %{root: root} do
      write_agent(root, "explorer", "x", "mode: subagent\n")
      id = "sub-depth-#{System.unique_integer([:positive])}"

      # the definition, not its name: only the human path goes through the
      # selection rule (a `mode: subagent` definition is not selectable)
      {explorer, _} = definition(root, "explorer")

      start_parent(id, root,
        interactive: true,
        agent: explorer,
        depth: 1,
        subagent_runner: child_runner("should not run")
      )

      :ok = Session.debug_gate(id, [task_call("t1", "explorer", "go")])

      {:ok, state} = Session.state(id)

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "may not start further subagents"
    end

    test "a child session's tool set excludes task", %{root: root} do
      write_agent(root, "explorer", "x", "mode: subagent\n")
      id = "sub-tools-#{System.unique_integer([:positive])}"
      {explorer, _} = definition(root, "explorer")
      start_parent(id, root, interactive: true, agent: explorer, depth: 1)

      {:ok, parent} = Session.state(id)

      child_tools =
        CodingAgent.Core.Session.ToolRunner.tools(
          parent.policy,
          CodingAgent.Core.Session.ToolRunner.scope(root, parent.mounts, "s", :rw,
            depth: parent.depth,
            subagents: parent.subagents
          )
        )

      refute "task" in Enum.map(child_tools, & &1.name)
    end

    test "a depth-1 session fails a gate-parked call closed instead of hanging", %{root: root} do
      # A subagent has no human channel (ADR 017): parking at the approval
      # gate would hang the parent's `Session.run/2` forever. The call is
      # denied in-round so the model reads it and adapts.
      toml = Path.join(root, "permissions.toml")
      File.write!(toml, "[permissions.write_file]\n\"*\" = \"ask\"\n")

      id = "sub-gate-#{System.unique_integer([:positive])}"
      policy = Permissions.load(nil, toml)

      {:ok, _} =
        Session.Supervisor.start_session(
          id: id,
          scope_root: root,
          policy: policy,
          test_mode: true,
          interactive: false,
          agent: "build",
          depth: 1
        )

      write = %{
        id: "w1",
        name: "write_file",
        arguments: %{"path" => "x.txt", "content" => "x"}
      }

      :ok = Session.debug_gate(id, [write])

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "a subagent has no human channel"
    end
  end

  describe "parallel delegation (ADR 018)" do
    test "multiple task calls run concurrently (up to the cap)", %{root: root} do
      write_agent(root, "explorer", "x", "mode: subagent\n")
      id = "sub-par-#{System.unique_integer([:positive])}"
      parent = self()

      # The runner announces its pid on entry, then blocks until released:
      # with a cap >= 3 all three enter BEFORE any is released, which is
      # exactly the concurrency this test proves.
      runner = fn state ->
        send(parent, {:entered, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        state = Session.debug_complete_turn(state, "done", [{:assistant, "done"}])
        {state, {:ok, state}}
      end

      start_parent(id, root, interactive: true, subagent_runner: runner)

      calls = for i <- 1..3, do: task_call("t#{i}", "explorer", "go #{i}")

      {gate_pid, monitor} =
        spawn_monitor(fn -> Session.debug_gate(id, calls) end)

      pids =
        for _ <- 1..3 do
          assert_receive {:entered, p}, 2_000
          p
        end

      for p <- pids, do: send(p, :release)

      assert_receive {:DOWN, ^monitor, :process, ^gate_pid, _}, 2_000

      {:ok, state} = Session.state(id)
      refute state.status == :error
    end

    test "results keep call order", %{root: root} do
      write_agent(root, "explorer", "x", "mode: subagent\n")
      id = "sub-order-#{System.unique_integer([:positive])}"

      # The answer names the task prompt, so ordering is observable in the
      # parent's context (the task tool results are appended in call order).
      runner = fn state ->
        prompt =
          state.context
          |> ReqLLM.Context.to_list()
          |> Enum.find_value(fn
            %ReqLLM.Message{role: :user} = msg -> message_text(msg)
            _ -> nil
          end)

        answer = "summary for #{prompt}"
        state = Session.debug_complete_turn(state, answer, [{:assistant, answer}])
        {state, {:ok, state}}
      end

      start_parent(id, root, interactive: true, subagent_runner: runner)

      :ok =
        Session.debug_gate(id, [
          task_call("t1", "explorer", "one"),
          task_call("t2", "explorer", "two"),
          task_call("t3", "explorer", "three")
        ])

      {:ok, state} = Session.state(id)

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ ~r/summary for.*one.*summary for.*two.*summary for.*three/s
    end
  end

  describe "the parent events (ADR 018)" do
    test "started and finished are broadcast on the PARENT channel", %{root: root} do
      write_agent(root, "explorer", "x", "mode: subagent\n")
      id = "sub-events-#{System.unique_integer([:positive])}"

      start_parent(id, root,
        interactive: true,
        subagent_runner: child_runner("done")
      )

      :ok = Session.subscribe(id)
      :ok = Session.debug_gate(id, [task_call("t1", "explorer", "go")])

      events = drain_events()
      on_exit(fn -> :ok end)

      assert Enum.any?(events, &match?({:subagent_started, _, "explorer", _}, &1))
      assert Enum.any?(events, &match?({:subagent_finished, _, :ok}, &1))
    end
  end

  describe "the child model (ADR 017 decision 5 + ADR 042)" do
    test "inherits the parent's model by default", %{root: root} do
      write_agent(root, "explorer", "x", "mode: subagent\n")
      id = "sub-model-default-#{System.unique_integer([:positive])}"

      start_parent(id, root,
        interactive: true,
        model: "openai:gpt-4o",
        subagent_runner: child_runner("done")
      )

      :ok = Session.subscribe(id)
      :ok = Session.debug_gate(id, [task_call("t1", "explorer", "go")])

      assert Enum.any?(drain_events(), &match?({:subagent_started, _, _, "openai:gpt-4o"}, &1))
    end

    test "config.subagent_model overrides the parent", %{root: root} do
      write_agent(root, "explorer", "x", "mode: subagent\n")

      File.write!(
        Path.join(root, ".coding-agent/config.toml"),
        ~s(subagent_model = "ollama:cheap")
      )

      id = "sub-model-config-#{System.unique_integer([:positive])}"

      start_parent(id, root,
        interactive: true,
        model: "openai:gpt-4o",
        subagent_runner: child_runner("done")
      )

      :ok = Session.subscribe(id)
      :ok = Session.debug_gate(id, [task_call("t1", "explorer", "go")])

      assert Enum.any?(drain_events(), &match?({:subagent_started, _, _, "ollama:cheap"}, &1))
    end

    test "a definition's pinned model beats config.subagent_model", %{root: root} do
      write_agent(root, "explorer", "x", "mode: subagent\nmodel: anthropic:claude-haiku-4-5\n")

      File.write!(
        Path.join(root, ".coding-agent/config.toml"),
        ~s(subagent_model = "ollama:cheap")
      )

      id = "sub-model-pin-#{System.unique_integer([:positive])}"

      start_parent(id, root,
        interactive: true,
        model: "openai:gpt-4o",
        subagent_runner: child_runner("done")
      )

      :ok = Session.subscribe(id)
      :ok = Session.debug_gate(id, [task_call("t1", "explorer", "go")])

      assert Enum.any?(
               drain_events(),
               &match?({:subagent_started, _, _, "anthropic:claude-haiku-4-5"}, &1)
             )
    end
  end

  # Collect every {:agent, id, event} the test process received (a short
  # settle window; the events are sent synchronously during debug_gate).
  defp drain_events(acc \\ []) do
    receive do
      {:agent, _id, event} -> drain_events([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  # The child id named by a {:subagent_finished, child_id, outcome} event.
  defp child_id_of(events) do
    Enum.find_value(events, fn
      {:subagent_finished, child_id, _} -> child_id
      _ -> nil
    end)
  end

  defp message_text(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp message_text(%ReqLLM.Message{content: t}) when is_binary(t), do: t
  defp message_text(_), do: ""
end
