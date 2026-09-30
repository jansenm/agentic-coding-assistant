defmodule CodingAgent.Core.CompactionTest do
  # async: false — the wall-clock-budget test mutates the GLOBAL
  # `:compaction_wall_clock_ms` app env. ExUnit runs all async modules
  # first, then sync modules serially, so a sync module cannot race an
  # async one. Was `async: true`, which let a concurrent compaction see
  # the 50ms budget and fail.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodingAgent.Core.Compaction
  alias CodingAgent.Core.Session.{Compactor, State, Usage}

  defp msg(text, role \\ :user) do
    %ReqLLM.Message{role: role, content: [ReqLLM.Message.ContentPart.text(text)]}
  end

  defp tool_msg(name, text) do
    %ReqLLM.Message{
      role: :tool,
      name: name,
      tool_call_id: "c-#{name}",
      content: [ReqLLM.Message.ContentPart.text(text)]
    }
  end

  defp assistant_call(name, args) do
    %ReqLLM.Message{
      role: :assistant,
      content: [],
      tool_calls: [
        %ReqLLM.ToolCall{id: "c-#{name}", function: %{name: name, arguments: Jason.encode!(args)}}
      ]
    }
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
          status: :idle,
          # a fixed small window so the limits are deterministic in tests
          context_window: 200_000,
          compaction_soft_limit: 100_000,
          compaction_hard_limit: 136_000
        ],
        opts
      )
    )
  end

  # -- pure plumbing (split / apply / render) -----------------------------------

  test "split: :none when there is nothing worth compacting" do
    assert Compaction.split([msg("a"), msg("b")]) == :none
  end

  test "split: keeps the system message out of the summary span" do
    assert {:ok, old, keep} = Compaction.split(ctx(90).messages)
    refute Enum.any?(old, &(&1.role == :system))
    refute Enum.any?(keep, &(&1.role == :system))
    # at least min_keep survive
    assert length(keep) >= Compaction.min_keep()
  end

  test "split: the tail never starts on a bare tool result" do
    # 1 user + 12 assistant/tool exchanges: force a cut that would land
    # on a tool result without the boundary rule
    msgs =
      [msg("hi", :user)] ++
        Enum.flat_map(1..12, fn i ->
          [assistant_call("read_file", %{path: "/f#{i}"}), tool_msg("read_file", "body #{i}")]
        end)

    assert {:ok, _old, keep} = Compaction.split(msgs)
    assert hd(keep).role in [:user, :assistant]
  end

  test "split: a kept assistant call keeps its tool results" do
    msgs =
      [msg("hi", :user)] ++
        Enum.flat_map(1..12, fn i ->
          [assistant_call("grep", %{pattern: "p#{i}"}), tool_msg("grep", "r#{i}")]
        end)

    assert {:ok, _old, keep} = Compaction.split(msgs)

    # if an assistant call is in the tail, its tool result follows it
    keep
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, t] ->
      if a.role == :assistant and (a.tool_calls || []) != [] do
        assert t.role == :tool
      end
    end)
  end

  test "apply: keeps the system message and prepends the summary" do
    compacted = Compaction.apply(ctx(30), "the summary")
    msgs = ReqLLM.Context.to_list(compacted)

    assert hd(msgs).role == :system
    assert Enum.at(msgs, 1).role == :user
    assert summary_text(Enum.at(msgs, 1)) =~ "the summary"
    assert summary_text(Enum.at(msgs, 1)) =~ "compacted"
  end

  test "apply on a tiny context is a no-op" do
    ctx = ctx(2)
    assert Compaction.apply(ctx, "s") == ctx
  end

  test "apply does not resurrect the system message count" do
    # the live bug: after compaction the stored context had ZERO system
    # messages, so with_environment/with_todos silently no-op'd
    compacted = Compaction.apply(ctx(30), "s")
    assert Enum.count(ReqLLM.Context.to_list(compacted), &(&1.role == :system)) == 1
  end

  test "summary_message?/prior_summary identify our synthetic summary" do
    compacted = Compaction.apply(ctx(30), "durable fact: 42")
    [sys, summary | _] = ReqLLM.Context.to_list(compacted)

    assert Compaction.summary_message?(summary)
    refute Compaction.summary_message?(sys)
    refute Compaction.summary_message?(msg("an ordinary user turn"))
    assert Compaction.prior_summary(compacted) =~ "durable fact: 42"
    # the wrapper header is stripped, so it can be fed back as prior-summary
    refute Compaction.prior_summary(compacted) =~ "Conversation summary"
  end

  test "prior_summary is nil when no summary is present" do
    assert Compaction.prior_summary(ctx(5)) == nil
  end

  test "render skips a prior summary (it is carried forward separately)" do
    compacted = Compaction.apply(ctx(30), "unique-prior-marker")
    rendered = Compaction.render(ReqLLM.Context.to_list(compacted))
    refute rendered =~ "unique-prior-marker"
  end

  test "apply replaces the prior summary, not accumulating them" do
    once = Compaction.apply(ctx(30), "first")
    twice = Compaction.apply(once, "second")
    msgs = ReqLLM.Context.to_list(twice)

    assert Enum.count(msgs, &Compaction.summary_message?/1) == 1
  end

  test "split excludes the prior summary from the span (review N16)" do
    # after a compaction the summary sits at the head; later messages
    # accumulate. A split must pick the LATER span, never the summary (else
    # render empties it and the provider summarizes nothing, overwriting the
    # summary).
    compacted = Compaction.apply(ctx(30), "prior fact")

    grown =
      ReqLLM.Context.to_list(compacted) ++
        for _ <- 1..40, do: msg(String.duplicate("x", 1000), :assistant)

    assert {:ok, old, keep} = Compaction.split(grown)
    refute Enum.any?(old, &Compaction.summary_message?/1)
    refute Enum.any?(keep, &Compaction.summary_message?/1)
    # and when nothing but the summary + min_keep remain, split is :none
    assert Compaction.split(ReqLLM.Context.to_list(compacted)) == :none
  end

  test "trim keeps the summary pinned, like the system prompt (review N20b)" do
    compacted = Compaction.apply(ctx(30), "durable fact 1056 tests")

    grown =
      ReqLLM.Context.to_list(compacted) ++
        for _ <- 1..60, do: msg(String.duplicate("x", 2000), :assistant)

    ctx = %ReqLLM.Context{messages: grown}
    assert {:ok, trimmed, dropped} = Compaction.trim(ctx, 100)
    assert dropped > 0

    kept = ReqLLM.Context.to_list(trimmed)
    assert Enum.any?(kept, &Compaction.summary_message?/1)
    assert Compaction.prior_summary(trimmed) =~ "durable fact 1056 tests"
    # the summary stays right after the system message
    assert Enum.at(kept, 0).role == :system
    assert Compaction.summary_message?(Enum.at(kept, 1))
  end

  # -- the summarizer request (template + rolling) ------------------------------

  test "apply caps an oversized summary so it cannot become the overflow (review N18)" do
    huge = String.duplicate("x", 100_000)
    compacted = Compaction.apply(ctx(30), huge)
    stored = Compaction.prior_summary(compacted)
    assert byte_size(stored) < 30_000
    assert stored =~ "summary truncated"
  end

  test "summary_prompt without a prior summary: template, no prior block" do
    prompt = Compaction.summary_prompt("USER: do the thing", nil)

    assert prompt =~ "<conversation>\nUSER: do the thing\n</conversation>"
    refute prompt =~ "<prior-summary>"
    # the full section template is present (none silently optional)
    for section <- [
          "## Objective",
          "## Important Details",
          "## Work State",
          "### Completed",
          "### Active",
          "### Blocked",
          "## Next Move",
          "## Relevant Files"
        ] do
      assert prompt =~ section
    end

    assert prompt =~ "Keep every section, even when empty"
    assert prompt =~ "Preserve exact file paths, symbols, commands, error strings"
    assert prompt =~ "Do not mention the summary process"
  end

  test "summary_prompt demands measurements and test results verbatim (review N17)" do
    prompt = Compaction.summary_prompt("USER: do the thing", nil)
    assert prompt =~ "measurements"
    assert prompt =~ "test results"
    assert prompt =~ "exit codes"
    assert prompt =~ "NUMBERS"
  end

  test "summary_prompt with a prior summary: carry-forward rules present" do
    prompt = Compaction.summary_prompt("USER: more", "## Objective\n- old goal")

    assert prompt =~ "<prior-summary>\n## Objective\n- old goal\n</prior-summary>"
    assert prompt =~ "Carry forward objectives"
    assert prompt =~ "the conversation wins"
    assert prompt =~ "anything you do not carry into the new summary is lost"
  end

  test "prior summary is framed as prior-summary, never as conversation (review N22)" do
    prompt = Compaction.summary_prompt("USER: more", "## Objective\n- old goal")
    # the prior must not appear inside the <conversation> block
    [conv_block | _] = String.split(prompt, "<prior-summary>", parts: 2)
    refute conv_block =~ "old goal"
  end

  test "summary_message?/1 tolerates leading whitespace (review N21)" do
    msg = %ReqLLM.Message{
      role: :user,
      content: [
        ReqLLM.Message.ContentPart.text(
          "  \n[Conversation summary — earlier messages were compacted]\n\nbody"
        )
      ]
    }

    assert Compaction.summary_message?(msg)
    assert Compaction.prior_summary([msg]) == "body"
  end

  test "a header-only summary has no prior body, not the header (review N21)" do
    msg = %ReqLLM.Message{
      role: :user,
      content: [
        ReqLLM.Message.ContentPart.text(
          "[Conversation summary — earlier messages were compacted to save context. The recent exchanges below are verbatim.]"
        )
      ]
    }

    assert Compaction.summary_message?(msg)
    assert Compaction.prior_summary([msg]) == nil
  end

  test "total_chars counts text parts" do
    msgs = [msg("hello"), msg("world", :assistant)]
    assert Compaction.total_chars(msgs) == 10
  end

  test "render flattens text blocks with roles" do
    rendered = Compaction.render([msg("hello"), msg("world", :assistant)])
    assert rendered == "[user] hello\n\n[assistant] world"
  end

  test "render carries tool names and call arguments (ADR 037)" do
    msgs = [
      assistant_call("read_file", %{path: "lib/foo.ex"}),
      tool_msg("read_file", "defmodule Foo")
    ]

    rendered = Compaction.render(msgs)
    assert rendered =~ "read_file"
    assert rendered =~ "lib/foo.ex"
    assert rendered =~ "[tool:read_file]"
  end

  test "render truncates a huge tool result with a marker" do
    rendered = Compaction.render([tool_msg("shell", String.duplicate("x", 5_000))])
    assert rendered =~ "truncated for the summary"
  end

  test "trim drops oldest complete exchanges, keeps the system message" do
    ctx = ctx(40, 5_000)
    assert {:ok, trimmed, dropped} = Compaction.trim(ctx, 1_000)
    assert dropped > 0
    msgs = ReqLLM.Context.to_list(trimmed)
    assert hd(msgs).role == :system
    assert length(msgs) < 41
  end

  test "trim is a no-op when already under target" do
    assert Compaction.trim(ctx(5), 1_000_000) == :none
  end

  # -- the session-level trigger decision (Compactor.decide/2) ------------------

  test "decide: known usage below the limit is :none (no chars fallback)" do
    s = state(usage: %{last_input_tokens: 20_000})
    assert Compactor.decide(s, 100_000) == :none
  end

  test "decide: projected chars can trigger even when the count lags" do
    # last_input_tokens is 20k (the provider has not seen the tool result
    # yet) but the context is already huge: the projected size triggers
    s = state(usage: %{last_input_tokens: 20_000}, context: ctx(400, 5_000))
    assert {:ok, {_old, _keep}} = Compactor.decide(s, 100_000)
  end

  test "decide: at/above the limit compacts" do
    s = state(usage: %{last_input_tokens: 136_000})
    assert {:ok, {old, keep}} = Compactor.decide(s, 136_000)
    assert length(keep) >= Compaction.min_keep()
    assert old != []
  end

  test "decide: no usage (first turn) falls back to the chars plan" do
    assert {:ok, {_old, _keep}} = Compactor.decide(state(), 100_000)
    assert Compactor.decide(state(context: ctx(3)), 100_000) == :none
  end

  # -- manual /compact (Compactor.compact_now/2) -------------------------------

  test "can_compact? is false for a context too short to split" do
    refute Compactor.can_compact?(state(context: ctx(3)))
    assert Compactor.can_compact?(state())
  end

  test "can_compact? is false in test_mode (the summary is a provider call)" do
    refute Compactor.can_compact?(state(test_mode: true))
  end

  test "compact_now summarizes BELOW both limits (the human asked)" do
    # last_input_tokens 1k: neither the soft nor the hard limit would fire,
    # but a manual compaction must still run.
    s = state(usage: %{last_input_tokens: 1_000})
    assert Compactor.decide(s, Compactor.soft_limit(s)) == :none

    {s2, true} =
      Compactor.compact_now(s, fn _state, span -> {:ok, "sum of #{byte_size(span)}"} end)

    msgs = ReqLLM.Context.to_list(s2.context)
    assert hd(msgs).role == :system
    assert Enum.at(msgs, 1).role == :user
    assert s2.compaction_backoff == 0
  end

  test "compact_now is a no-op when there is nothing to summarize" do
    s = state(context: ctx(3))
    {s2, false} = Compactor.compact_now(s, fn _state, _span -> flunk("must not summarize") end)
    assert s2 == s
  end

  test "compact_now is structurally inert in test_mode" do
    s = state(test_mode: true)
    {s2, false} = Compactor.compact_now(s, fn _state, _span -> flunk("must not summarize") end)
    assert s2 == s
  end

  # -- warn-once ----------------------------------------------------------------

  test "warn_approaching: warns once at 80% of the soft limit" do
    s0 = state(usage: %{last_input_tokens: 90_000})
    # soft limit 100k -> warn at 80k; 90k warns
    {s1, true} = Compactor.warn_approaching(s0)
    assert s1.compaction_warned == true
    {s2, false} = Compactor.warn_approaching(s1)
    assert s2 == s1
  end

  test "warn_threshold/1 is 80% of the soft limit the sidebar shares" do
    s = state()
    assert Compactor.warn_threshold(s) == trunc(Compactor.soft_limit(s) * 0.8)
  end

  test "warn_approaching: does not warn below 80%" do
    s0 = state(usage: %{last_input_tokens: 50_000})
    {s1, false} = Compactor.warn_approaching(s0)
    assert s1.compaction_warned == false
  end

  # -- the operation: task budget, failure, abnormal exit ------------------------

  test "maybe_compact applies the summary and reports changed" do
    s = state(usage: %{last_input_tokens: 136_000})

    {s2, true} =
      Compactor.maybe_compact(s, fn _state, span -> {:ok, "summary of #{byte_size(span)}"} end)

    msgs = ReqLLM.Context.to_list(s2.context)
    # system + summary + tail
    assert hd(msgs).role == :system
    assert Enum.at(msgs, 1).role == :user
    assert s2.compaction_backoff == 0
    assert s2.compaction_warned == false
  end

  test "a successful compaction resets last_input_tokens to the shrunk size" do
    # The bug (found live): the sidebar shows Usage.last_input_tokens, and
    # a compaction left it at the pre-compaction 136k, so the display kept
    # showing the old number until the next provider turn happened to
    # report a fresh count.
    s = state(usage: %{last_input_tokens: 136_000})
    assert Usage.last_input_tokens(s.usage) == 136_000

    {s2, true} = Compactor.maybe_compact(s, fn _state, _span -> {:ok, "a short summary"} end)

    # the count now reflects the compacted context, not the old 136k
    assert Usage.last_input_tokens(s2.usage) < 136_000

    assert Usage.last_input_tokens(s2.usage) ==
             div(Compaction.total_chars(s2.context.messages), 4)

    # and it is what the next decision sees, so the shrunk context does
    # not immediately look over the limit again
    assert Compactor.decide(s2, Compactor.soft_limit(s2)) == :none
  end

  test "maybe_compact_idle uses the soft limit, not the hard one" do
    # 101k is between the soft (100k) and the hard (136k) limit: the idle
    # pass compacts, the pre-call hard pass would not.
    s = state(usage: %{last_input_tokens: 101_000})
    assert Compactor.decide(s, Compactor.hard_limit(s)) == :none
    assert {:ok, _} = Compactor.decide(s, Compactor.soft_limit(s))

    {_s2, true} = Compactor.maybe_compact_idle(s, fn _state, _span -> {:ok, "idle summary"} end)
  end

  test "maybe_compact_idle below the soft limit does nothing" do
    s = state(usage: %{last_input_tokens: 50_000})
    {s2, false} = Compactor.maybe_compact_idle(s, fn _state, _span -> flunk("must not") end)
    assert s2 == s
  end

  test "maybe_compact on summarizer error keeps the context and backs off" do
    s = state(usage: %{last_input_tokens: 136_000})

    log =
      capture_log(fn ->
        {s2, false} = Compactor.maybe_compact(s, fn _state, _span -> {:error, :provider_down} end)

        assert s2.context == s.context
        assert s2.compaction_backoff == 3
      end)

    assert log =~ "compaction failed, keeping full context"
    assert log =~ ":provider_down"
  end

  test "maybe_compact on abnormal task exit keeps the context and backs off" do
    s = state(usage: %{last_input_tokens: 136_000})

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

  test "maybe_compact enforces the wall-clock budget" do
    Application.put_env(:coding_agent, :compaction_wall_clock_ms, 50)

    try do
      s = state(usage: %{last_input_tokens: 136_000})

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

  test "maybe_compact during backoff skips and counts down (under the hard limit)" do
    s = state(usage: %{last_input_tokens: 101_000}, compaction_backoff: 2)
    {s2, false} = Compactor.maybe_compact(s, fn _state, _span -> flunk("must not summarize") end)
    assert s2.compaction_backoff == 1
  end

  test "maybe_compact during backoff still trims at the hard limit" do
    s =
      state(
        usage: %{last_input_tokens: 200_000},
        context: ctx(400, 5_000),
        compaction_backoff: 2
      )

    log = capture_log(fn -> assert {_s2, true} = Compactor.maybe_compact(s) end)
    assert log =~ "hard compaction limit"
  end

  test "maybe_compact in test mode is a structural skip" do
    s = state(usage: %{last_input_tokens: 136_000}, test_mode: true)
    {s2, false} = Compactor.maybe_compact(s, fn _state, _span -> flunk("must not summarize") end)
    assert s2 == s
  end

  test "maybe_compact below the limit only warns once" do
    s = state(usage: %{last_input_tokens: 90_000})
    {s1, true} = Compactor.maybe_compact(s, fn _state, _span -> flunk("must not summarize") end)
    assert s1.compaction_warned == true

    {s2, false} = Compactor.maybe_compact(s1, fn _state, _span -> flunk("must not summarize") end)
    assert s2 == s1
  end

  defp summary_text(%ReqLLM.Message{content: parts}) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t
      _ -> ""
    end)
  end
end
