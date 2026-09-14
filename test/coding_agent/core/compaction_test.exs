defmodule CodingAgent.Core.CompactionTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Compaction

  defp msg(text, role \\ :user) do
    %ReqLLM.Message{role: role, content: [ReqLLM.Message.ContentPart.text(text)]}
  end

  defp ctx(n, chars_per \\ 1000) do
    msgs =
      for _i <- 1..n do
        msg(String.pad_leading("m", chars_per, "x"), :assistant)
      end

    %ReqLLM.Context{messages: [msg("system", :system) | msgs]}
  end

  test "plan: none below the threshold" do
    assert Compaction.plan(ctx(3)) == :none
  end

  # locks the compaction trigger decision (Session.compaction_plan/2):
  # known usage below the token trigger must NEVER compact — the old
  # chars fallback fired at 80K chars (~20K tokens) and stalled every
  # turn behind a slow summarize call (found live: the review session
  # hung, then the session crashed on a CaseClauseError in maybe_compact)
  describe "compaction_plan/2 (session trigger)" do
    alias CodingAgent.Core.Session

    defp state_with_usage(usage) do
      %CodingAgent.Core.Session.State{
        id: "t",
        context: ctx(90),
        model: "ollama:test",
        status: :idle,
        usage: usage
      }
    end

    @trigger 180_000

    test "known usage below the trigger: :none (no chars fallback)" do
      # 100K chars would trigger the old chars path; 20K tokens is far
      # below the 180K trigger
      assert Session.compaction_plan(
               %{state_with_usage(nil) | usage: %{last_input_tokens: 20_000}},
               @trigger
             ) == :none
    end

    test "known usage at/above the trigger compacts" do
      assert {:ok, _old, _keep} =
               Session.compaction_plan(
                 %{state_with_usage(nil) | usage: %{last_input_tokens: 180_000}},
                 @trigger
               )
    end

    test "no usage (first turn): chars fallback applies" do
      fat = ctx(90)

      assert {:ok, _old, _keep} =
               Session.compaction_plan(%{state_with_usage(nil) | context: fat}, @trigger)

      thin = ctx(3)
      assert Session.compaction_plan(%{state_with_usage(nil) | context: thin}, @trigger) == :none
    end
  end

  test "plan: splits old/keep above the threshold" do
    assert {:ok, old, keep} = Compaction.plan(ctx(90))
    # system message counts as old (compacted), keep_recent stay verbatim
    assert length(keep) == Compaction.keep_recent()
    assert length(old) == 91 - Compaction.keep_recent()
  end

  test "apply: replaces the old span with one summary user message" do
    ctx = ctx(30)
    compacted = Compaction.apply(ctx, "the summary")

    [summary | keep] = ReqLLM.Context.to_list(compacted)
    assert summary.role == :user
    assert ReqLLM.Context.to_list(compacted) |> length() == Compaction.keep_recent() + 1
    assert keep == Enum.drop(ReqLLM.Context.to_list(ctx), 31 - Compaction.keep_recent())
    assert summary_text(summary) =~ "the summary"
    assert summary_text(summary) =~ "compacted"
  end

  test "apply on a tiny context is a no-op" do
    ctx = ctx(2)
    assert Compaction.apply(ctx, "s") == ctx
  end

  test "total_chars counts text parts" do
    msgs = [msg("hello"), msg("world", :assistant)]
    assert Compaction.total_chars(msgs) == 10
  end

  defp summary_text(%ReqLLM.Message{content: parts}) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t
      _ -> ""
    end)
  end
end
