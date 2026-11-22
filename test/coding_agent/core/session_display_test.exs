# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.DisplayTest do
  # ADR 020 slice 3b: the persisted display view.
  #
  # The two bugs this fixes, both observed live:
  #   1. reasoning was broadcast to the UI and discarded — gone on resume;
  #   2. compaction rewrote the only persisted view, so a resumed
  #      transcript showed a lossy, compacted history.
  #
  # The display view is the immutable record of what the user saw,
  # append-only, and lives beside (not inside) the compaction-mutable
  # agent view.
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.Store
  alias CodingAgent.Core.Session.State

  @tmp_root System.tmp_dir!() |> Path.join("agent-display-#{System.unique_integer()}")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  # A turn_runner that mimics a streamed turn: it records the blocks a
  # real stream would have produced and completes the turn. It reaches
  # the REAL display-write paths (begin_run appends the user prompt,
  # complete_turn appends the blocks), so the test exercises production
  # code, not a mock of it.
  defp streaming_runner(blocks) do
    fn state ->
      state = Session.debug_complete_turn(state, "streamed answer", blocks)
      {state, {:ok, state}}
    end
  end

  describe "the display view records what the user saw" do
    test "a turn appends the user prompt, the reasoning and the answer, in order" do
      id = "disp-turn-#{System.unique_integer([:positive])}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true,
          turn_runner:
            streaming_runner([
              {:reasoning, "let me think"},
              {:assistant, "here is the answer"}
            ])
        )

      # run the turn through the real begin_run path
      {:ok, _} = Session.run(id, "please help")

      assert [
               %{kind: :user, text: "please help"},
               %{kind: :reasoning, text: "let me think"},
               %{kind: :assistant, text: "here is the answer"}
             ] = Store.display(id)
    end

    test "reasoning survives a resume (the bug the old store had)" do
      id = "disp-resume-#{System.unique_integer([:positive])}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true,
          turn_runner: streaming_runner([{:reasoning, "SECRET-THOUGHT"}, {:assistant, "done"}])
        )

      {:ok, _} = Session.run(id, "go")

      # the agent view has no reasoning; the display view does
      {:ok, state} = Session.state(id)
      refute inspect(state.context) =~ "SECRET-THOUGHT"

      display = Store.display(id)
      assert Enum.any?(display, &(&1.kind == :reasoning and &1.text =~ "SECRET-THOUGHT"))
    end

    test "compaction cannot erase the display view" do
      id = "disp-compact-#{System.unique_integer([:positive])}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true,
          turn_runner: streaming_runner([{:assistant, "ORIGINAL-ANSWER"}])
        )

      {:ok, _} = Session.run(id, "first")

      before = Store.display(id)
      assert Enum.any?(before, &(&1.text =~ "ORIGINAL-ANSWER"))

      # simulate the compaction mutation of the AGENT view: replace the
      # context with a summary and re-save (what apply_summary does)
      {:ok, state} = Session.state(id)

      compacted =
        %{state | context: ReqLLM.Context.new([ReqLLM.Context.user("Conversation summary: …")])}

      :ok = Store.save(compacted)

      # the display view is untouched: append-only, compaction-immune
      assert Store.display(id) == before
    end

    test "a non-streamed turn's answer is still recorded (no deltas)" do
      id = "disp-nostream-#{System.unique_integer([:positive])}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true,
          turn_runner: streaming_runner([])
        )

      {:ok, _} = Session.run(id, "hi")

      # no blocks streamed, but the final answer must still be visible
      assert Enum.any?(
               Store.display(id),
               &(&1.kind == :assistant and &1.text =~ "streamed answer")
             )
    end
  end

  describe "the resumed transcript source" do
    test "a session with display rows is read from the display view" do
      id = "disp-tr-#{System.unique_integer([:positive])}"

      :ok =
        Store.save(State.new(id: id, context: ReqLLM.Context.new(), model: "m", status: :idle))

      :ok = Store.append_display(id, :reasoning, "thought")
      :ok = Store.append_display(id, :assistant, "answer")

      # the TUI's mapping helper is private; assert the data it needs
      assert [%{kind: :reasoning}, %{kind: :assistant}] = Store.display(id)
    end
  end

  describe "a stop with no streamed text" do
    test "ends the turn with a note, not an empty assistant message (found live)" do
      # The bug: a stop during reasoning (nothing but thoughts streamed)
      # hit `complete_turn("", [])`, which appended an EMPTY assistant
      # message to the context and broadcast an empty `llm_message` — no
      # answer, no note, indistinguishable from "the agent just stopped".
      id = "disp-stop-#{System.unique_integer([:positive])}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true
        )

      {:ok, state} = Session.state(id)
      state = Session.interrupted_turn(state, "")

      # idle, and NO empty assistant message was appended
      assert state.status == :idle

      refute Enum.any?(state.context.messages, fn m ->
               m.role == :assistant and m.content == [] and (m.tool_calls || []) == []
             end)

      # a visible reason reached the transcript
      assert Enum.any?(Store.display(id), &(&1.kind == :info and &1.text =~ "stopped"))

      # the flag is cleared so the next turn starts clean
      refute CodingAgent.Core.Interrupt.requested?(id)
    end

    test "keeps the partial text when something streamed" do
      id = "disp-stop-partial-#{System.unique_integer([:positive])}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true
        )

      {:ok, state} = Session.state(id)
      state = Session.interrupted_turn(state, "half an answer")

      assert state.status == :idle
      assert Enum.any?(state.context.messages, &(&1.role == :assistant))

      assert Enum.any?(
               Store.display(id),
               &(&1.kind == :assistant and &1.text =~ "half an answer")
             )
    end
  end
end
