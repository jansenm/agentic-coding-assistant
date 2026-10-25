defmodule CodingAgent.Core.Session.IdleCompactionTest do
  @moduledoc """
  Session-level integration for ADR 037's idle (soft-limit) pass: after a
  turn ends the session starts a background summary, guarded by a context
  fingerprint so a result for a context that has since changed is
  discarded. The provider is replaced by the `idle_compaction_runner`
  seam, so no LLM is reached.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Compaction
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.{Compactor, State, Usage}

  @tmp_root System.tmp_dir!() |> Path.join("agent-idle-#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    :ok
  end

  # A context large enough to be over the soft limit for a small window.
  # The window/limits are pinned explicitly so the test is independent of
  # the ambient config and catalog.
  defp fat_context do
    msgs =
      for i <- 1..40 do
        %ReqLLM.Message{
          role: :assistant,
          content: [ReqLLM.Message.ContentPart.text(String.pad_leading("m#{i}", 2_000, "x"))]
        }
      end

    %ReqLLM.Context{messages: [ReqLLM.Context.system("system") | msgs]}
  end

  # The turn body: complete the turn (ends idle) so the session's
  # finish_worker path runs and starts the idle pass.
  defp completing_runner(state) do
    state = Session.debug_complete_turn(state, "done", [{:assistant, "done"}])
    {state, {:ok, state}}
  end

  # NO wipe, per test or at module end: every session gets its OWN scope
  # root (see `start/2`), and a session outlives the test that started it
  # (it lives in the session supervisor). The checkpoint-reconcile
  # `Task.start`ed git call (review N54/N63) waits on the shared store
  # before its first port, so under load it can arrive after the test body
  # returned; deleting the root under it made `{:cd, root}` fail and
  # erl_child_setup printed "spawn: Could not cd to …" into the suite's
  # log — a warning no test asserts (the AGENTS.md rule). The run-scoped
  # TMPDIR (`test_helper.exs`) owns the tree.
  defp start(id, opts) do
    root = Path.join(@tmp_root, id)
    File.mkdir_p!(root)
    CodingAgent.TestScope.declare_window!(root)

    base = [
      id: id,
      scope_root: root,
      model: "ollama:test",
      test_mode: false,
      turn_runner: &completing_runner/1,
      context: fat_context(),
      usage: %{input_tokens: 0, output_tokens: 0, last_input_tokens: 300_000, cost: nil}
    ]

    {:ok, _} = CodingAgent.Core.Session.Supervisor.start_session(Keyword.merge(base, opts))
  end

  # The limits are resolved at init from the 500k fallback window (the
  # hand-pinned context is not a catalog model): soft 250k, hard 436k.
  test "a turn that ends idle starts the soft pass and applies its summary" do
    id = "idle-apply-#{System.unique_integer()}"
    parent = self()

    runner = fn state ->
      send(parent, {:idle_ran, length(state.context.messages)})

      # emulate the compactor: replace the old span with a summary message
      summary = %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("S")]}
      trimmed = %{state | context: %{state.context | messages: [summary]}}

      {trimmed, true}
    end

    start(id, idle_compaction_runner: runner)

    assert {:ok, _} = Session.run(id, "hello")
    assert_receive {:idle_ran, n}, 1_000
    assert n > 0

    # the session adopted the background result
    assert eventually(fn ->
             {:ok, st} = Session.state(id)
             length(ReqLLM.Context.to_list(st.context)) == 1
           end)
  end

  test "the adopted background result lowers the displayed token count" do
    # The live bug: after the soft pass the sidebar still showed the
    # pre-compaction count. The worker resets last_input_tokens to the
    # shrunk context's estimate (Compactor.note_shrunk_context/1); the
    # session must adopt that usage, not only the context.
    id = "idle-usage-#{System.unique_integer()}"

    runner = fn state ->
      summary = %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("S")]}
      context = %{state.context | messages: [summary]}
      usage = %{state.usage | last_input_tokens: 42}

      {%{state | context: context, usage: usage}, true}
    end

    start(id, idle_compaction_runner: runner)

    assert {:ok, _} = Session.run(id, "hello")

    assert eventually(fn ->
             {:ok, st} = Session.state(id)
             st.usage.last_input_tokens == 42
           end)
  end

  test "a stale idle result (context changed) is discarded" do
    id = "idle-stale-#{System.unique_integer()}"
    parent = self()

    # The idle runner blocks until released, so the test can start a new
    # turn (which changes the context) WHILE the summary is "running";
    # the result must then be discarded by the fingerprint guard.
    runner = fn state ->
      send(parent, {:idle_started, self()})

      receive do
        :release -> :ok
      after
        2_000 -> :ok
      end

      summary = %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("S")]}
      {%{state | context: %{state.context | messages: [summary]}}, true}
    end

    start(id, idle_compaction_runner: runner)

    assert {:ok, _} = Session.run(id, "hello")
    assert_receive {:idle_started, idle_task}, 1_000

    # change the context while the idle summary is in flight
    assert {:ok, _} = Session.run(id, "again")

    send(idle_task, :release)

    # the stale 1-message summary must never be adopted
    refute eventually(fn ->
             {:ok, st} = Session.state(id)
             length(ReqLLM.Context.to_list(st.context)) == 1
           end)
  end

  test "the soft pass does not start below the soft limit" do
    id = "idle-below-#{System.unique_integer()}"
    parent = self()

    runner = fn state ->
      send(parent, :idle_ran)
      {state, false}
    end

    # a small context and modest usage: under the 250k soft limit
    small = %ReqLLM.Context{messages: [ReqLLM.Context.system("s"), ReqLLM.Context.user("hi")]}

    start(id,
      idle_compaction_runner: runner,
      context: small,
      usage: %{input_tokens: 0, output_tokens: 0, last_input_tokens: 1_000, cost: nil}
    )

    assert {:ok, _} = Session.run(id, "hello")
    refute_receive :idle_ran, 300
  end

  test "Session.compact/1 runs the manual pass on demand (below the limits)" do
    id = "manual-#{System.unique_integer()}"
    parent = self()

    runner = fn state ->
      send(parent, {:manual_ran, length(state.context.messages)})
      summary = %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("S")]}
      {%{state | context: %{state.context | messages: [summary]}}, true}
    end

    # last_input_tokens 1k: no automatic limit would fire
    start(id,
      idle_compaction_runner: runner,
      usage: %{input_tokens: 0, output_tokens: 0, last_input_tokens: 1_000, cost: nil}
    )

    assert Session.compact(id) == :started
    assert_receive {:manual_ran, n}, 1_000
    assert n > 0

    assert eventually(fn ->
             {:ok, st} = Session.state(id)
             length(ReqLLM.Context.to_list(st.context)) == 1
           end)
  end

  test "Session.compact/1 reports :nothing when there is nothing to compact" do
    id = "manual-none-#{System.unique_integer()}"
    small = %ReqLLM.Context{messages: [ReqLLM.Context.system("s"), ReqLLM.Context.user("hi")]}

    start(id,
      idle_compaction_runner: fn _ -> flunk("must not run") end,
      context: small
    )

    assert Session.compact(id) == :nothing
  end

  test "Compactor projected size picks the larger of count and chars/4" do
    state = %State{
      id: "x",
      context: fat_context(),
      model: "ollama:test",
      status: :idle,
      usage: Usage.from_map(%{last_input_tokens: 10})
    }

    # the context is ~80k chars -> ~20k tokens, far above the stale 10
    assert Compactor.projected_tokens(state) >= 20_000
  end

  test "Compaction.apply keeps the system prompt (the live regression)" do
    compacted = Compaction.apply(fat_context(), "summary")
    assert Enum.count(ReqLLM.Context.to_list(compacted), &(&1.role == :system)) == 1
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
