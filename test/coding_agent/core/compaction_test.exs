defmodule CodingAgent.Core.CompactionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodingAgent.Core.Compaction
  alias CodingAgent.Core.Session.{Compactor, State}

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

  defp state(opts \\ []) do
    struct!(
      State,
      Keyword.merge(
        [
          id: "compaction-test",
          context: ctx(90),
          model: "ollama:test",
          status: :idle
        ],
        opts
      )
    )
  end

  @trigger 180_000

  # -- pure plumbing (plan / apply / render) ------------------------------------

  test "plan: none below the threshold" do
    assert Compaction.plan(ctx(3)) == :none
  end

  test "plan: splits old/keep above the threshold" do
    assert {:ok, old, keep} = Compaction.plan(ctx(90))
    # system message counts as old (compacted), keep_recent stay verbatim
    assert length(keep) == Compaction.keep_recent()
    assert length(old) == 91 - Compaction.keep_recent()
  end

  test "plan_tokens: :none below the trigger" do
    assert Compaction.plan_tokens(ctx(90), 100_000, 500_000) == :none
  end

  test "plan_tokens: compacts at the absolute threshold, not a window percentage" do
    # the opencode lesson: an absolute trigger (default 180k) — a big
    # window must NOT push compaction later
    assert Compaction.plan_tokens(ctx(90), 179_999, 180_000) == :none
    assert {:ok, _old, _keep} = Compaction.plan_tokens(ctx(90), 180_000, 180_000)

    # 300k context with a 500k window still compacts (the %-trigger
    # would have waited for 350k — exactly the failure mode being fixed)
    assert {:ok, _old, _keep} = Compaction.plan_tokens(ctx(90), 300_000, 180_000)
  end

  test "plan_tokens: no usage data (0) never triggers" do
    assert Compaction.plan_tokens(ctx(90), 0, 500_000) == :none
  end

  test "apply: replaces the old span with one summary user message" do
    compacted = Compaction.apply(ctx(30), "the summary")

    [summary | keep] = ReqLLM.Context.to_list(compacted)
    assert summary.role == :user
    assert ReqLLM.Context.to_list(compacted) |> length() == Compaction.keep_recent() + 1
    assert keep == Enum.drop(ReqLLM.Context.to_list(ctx(30)), 31 - Compaction.keep_recent())
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

  test "render flattens the span to [role] text blocks" do
    rendered = Compaction.render([msg("hello"), msg("world", :assistant)])
    assert rendered == "[user] hello\n\n[assistant] world"
  end

  defp summary_text(%ReqLLM.Message{content: parts}) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t
      _ -> ""
    end)
  end

  # -- the session-level trigger decision (Compactor.decide/2) ------------------

  # locks the compaction trigger decision: known usage below the token
  # trigger must NEVER compact — the old chars fallback fired at 80K
  # chars (~20K tokens) and stalled every turn behind a slow summarize
  # call (found live: the review session hung, then the session crashed
  # on a CaseClauseError in maybe_compact)

  test "decide: known usage below the trigger is :none (no chars fallback)" do
    # 100K chars would trigger the chars path; 20K tokens is far below
    # the 180K trigger
    s = state(usage: %{last_input_tokens: 20_000})
    assert Compactor.decide(s, @trigger) == :none
  end

  test "decide: known usage at/above the trigger compacts" do
    s = state(usage: %{last_input_tokens: 180_000})
    assert {:ok, {old, keep}} = Compactor.decide(s, @trigger)
    assert length(keep) == Compaction.keep_recent()
    assert length(old) == 91 - Compaction.keep_recent()
  end

  test "decide: no usage (first turn) falls back to the chars plan" do
    assert {:ok, {_old, _keep}} = Compactor.decide(state(), @trigger)
    assert Compactor.decide(state(context: ctx(3)), @trigger) == :none
  end

  # -- warn-once ----------------------------------------------------------------

  test "warn_approaching: warns once at 80% of the trigger" do
    s0 = state(usage: %{last_input_tokens: 150_000})
    # 150k >= 144k (80% of 180k) -> warns
    {s1, true} = Compactor.warn_approaching(s0, @trigger)
    assert s1.compaction_warned == true

    # second call: no double warn
    {s2, false} = Compactor.warn_approaching(s1, @trigger)
    assert s2 == s1
  end

  test "warn_threshold/0 is the single 80% source the sidebar and warner share" do
    # the sidebar used to re-hardcode 0.8; the fraction now lives here
    assert Compactor.warn_threshold() == trunc(Compactor.trigger() * 0.8)
  end

  test "warn_approaching: does not warn below 80%" do
    s0 = state(usage: %{last_input_tokens: 100_000})
    {s1, false} = Compactor.warn_approaching(s0, @trigger)
    assert s1.compaction_warned == false
  end

  # -- the operation: task budget, failure, abnormal exit ------------------------

  # the summarize result is applied and reported as changed
  test "maybe_compact applies the summary and reports changed" do
    s = state(usage: %{last_input_tokens: 180_000})

    {s2, true} =
      Compactor.maybe_compact(s, fn _state, span -> {:ok, "summary of #{byte_size(span)}"} end)

    msgs = ReqLLM.Context.to_list(s2.context)
    assert length(msgs) == Compaction.keep_recent() + 1
    assert s2.compaction_backoff == 0
    # the next approach to the trigger warns again (warn-once per approach)
    assert s2.compaction_warned == false
  end

  # a summarizer error degrades: keep the full context, set the backoff
  test "maybe_compact on summarizer error keeps the context and backs off" do
    s = state(usage: %{last_input_tokens: 180_000})

    log =
      capture_log(fn ->
        {s2, false} = Compactor.maybe_compact(s, fn _state, _span -> {:error, :provider_down} end)

        assert s2.context == s.context
        assert s2.compaction_backoff == 3
      end)

    assert log =~ "compaction failed, keeping full context"
    assert log =~ ":provider_down"
  end

  # an abnormal task exit must degrade like an error — the unhandled
  # {:exit, _} used to be a CaseClauseError that killed the session
  # mid-turn (found live)
  test "maybe_compact on abnormal task exit keeps the context and backs off" do
    s = state(usage: %{last_input_tokens: 180_000})

    log =
      capture_log(fn ->
        {s2, false} =
          Compactor.maybe_compact(s, fn _state, _span -> raise "summarizer boom" end)

        assert s2.context == s.context
        assert s2.compaction_backoff == 3
      end)

    assert log =~ "summarizer boom"
    assert log =~ "compaction failed, keeping full context"
  end

  # the wall-clock budget: a summarizer that never returns is killed at
  # the budget and treated as a failure (config-overridable so this
  # test runs in milliseconds, not 90s)
  test "maybe_compact enforces the wall-clock budget" do
    Application.put_env(:coding_agent, :compaction_wall_clock_ms, 50)

    try do
      s = state(usage: %{last_input_tokens: 180_000})

      log =
        capture_log(fn ->
          {s2, false} =
            Compactor.maybe_compact(s, fn _state, _span -> Process.sleep(5_000) end)

          assert s2.context == s.context
          assert s2.compaction_backoff == 3
        end)

      assert log =~ "compaction summarize exceeded"
    after
      Application.delete_env(:coding_agent, :compaction_wall_clock_ms)
    end
  end

  # backoff counts down without touching the context
  test "maybe_compact during backoff skips and counts down" do
    s = state(usage: %{last_input_tokens: 180_000}, compaction_backoff: 2)
    {s2, false} = Compactor.maybe_compact(s, fn _state, _span -> flunk("must not summarize") end)
    assert s2.compaction_backoff == 1
  end

  # tests are LLM-free: no summarizer call in test mode, structurally
  test "maybe_compact in test mode is a structural skip" do
    s = state(usage: %{last_input_tokens: 180_000}, test_mode: true)
    {s2, false} = Compactor.maybe_compact(s, fn _state, _span -> flunk("must not summarize") end)
    assert s2 == s
  end

  # known-below-usage: warn path — the warn flag flip is a persisted
  # change (changed?: true), the summarizer must not run
  test "maybe_compact below the trigger only warns once" do
    s = state(usage: %{last_input_tokens: 150_000})
    {s1, true} = Compactor.maybe_compact(s, fn _state, _span -> flunk("must not summarize") end)
    assert s1.compaction_warned == true

    {s2, false} = Compactor.maybe_compact(s1, fn _state, _span -> flunk("must not summarize") end)
    assert s2 == s1
  end
end
