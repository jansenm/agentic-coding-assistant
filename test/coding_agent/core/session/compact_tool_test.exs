# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.CompactToolTest do
  @moduledoc """
  The agent's own `compact` tool (ADR 040 OQ1, answered 2026-09-30): the
  model can summarize the older span MID-TURN, not only by ending its
  turn. Intercepted by the session like `todowrite`/`question` (never
  executed by `ToolRunner`), so the callback is a safety net.

  The provider is replaced by the `idle_compaction_runner` seam (reused
  for the in-turn path), so no LLM is reached.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Tools

  @tmp_root System.tmp_dir!() |> Path.join("agent-compact-#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    :ok
  end

  defp compact_call(id \\ "c1") do
    %{id: id, name: "compact", arguments: %{}}
  end

  # A context with a whole old exchange to summarize.
  defp context do
    msgs =
      for i <- 1..6 do
        %ReqLLM.Message{
          role: :assistant,
          content: [ReqLLM.Message.ContentPart.text("m#{i} " <> String.duplicate("x", 2_000))]
        }
      end

    %ReqLLM.Context{messages: [ReqLLM.Context.system("sys") | msgs]}
  end

  defp start(id, opts \\ []) do
    base = [
      id: id,
      scope_root: @tmp_root,
      model: "ollama:test",
      test_mode: true,
      context: context(),
      usage: %{input_tokens: 0, output_tokens: 0, last_input_tokens: 10_000, cost: nil}
    ]

    {:ok, _} = CodingAgent.Core.Session.Supervisor.start_session(Keyword.merge(base, opts))
  end

  test "the tool is registered and named" do
    assert Tools.Compact.name() == "compact"
    assert Enum.any?(Tools.all(%{root: "."}), &(&1.name == "compact"))
  end

  test "a compact call shrinks the context and returns a result in the round" do
    id = "compact-apply-#{System.unique_integer([:positive])}"

    # the seam replaces the summarizer: drop the old span, keep a summary
    runner = fn state ->
      summary = %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("S")]}
      trimmed = %{state | context: %{state.context | messages: [summary]}}

      {trimmed, :changed}
    end

    start(id, idle_compaction_runner: runner)

    before = Session.state(id) |> elem(1) |> Map.get(:context) |> ReqLLM.Context.to_list()
    :ok = Session.debug_gate(id, [compact_call()])

    {:ok, st} = Session.state(id)
    after_msgs = ReqLLM.Context.to_list(st.context)

    # the old exchange was summarized: fewer messages, and a compact result
    # is the last message in the context
    assert length(after_msgs) < length(before)
    last = List.last(st.context.messages)
    assert last.role in [:user, :tool]
    assert Enum.any?(st.context.messages, &(&1.role == :user and text(&1) =~ "S"))
  end

  test "the 'reclaimed' number measures the stored context, not the provider overhead (N42)" do
    id = "compact-reclaimed-#{System.unique_integer([:positive])}"

    # a summarizer that keeps a tiny context (a big, honest shrink)
    runner = fn state ->
      summary = %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("S")]}
      {%{state | context: %{state.context | messages: [summary]}}, :changed}
    end

    # the provider's last_input_tokens is INFLATED (framework prompt + tool
    # schemas are not in the stored messages). The old code subtracted
    # projected_tokens (max of that and chars/4), so "reclaimed" carried
    # the whole overhead, and could even go NEGATIVE while claiming a win.
    start(id,
      idle_compaction_runner: runner,
      usage: %{input_tokens: 0, output_tokens: 0, last_input_tokens: 4_300, cost: nil}
    )

    :ok = Session.debug_gate(id, [compact_call()])

    {:ok, st} = Session.state(id)

    content =
      Enum.find_value(st.context.messages, fn m ->
        if m.role == :tool, do: text(m)
      end)

    # the stored context was 6 msgs x ~2k chars = ~3k tokens, now 1 msg:
    # reclaimed must be well under the inflated 4_300, i.e. it did not add
    # the ~4k overhead, and it is never negative
    assert content =~ "reclaimed"
    [_, n] = Regex.run(~r/~(\d+) tokens reclaimed/, content)
    reclaimed = String.to_integer(n)
    assert reclaimed > 0
    refute content =~ "-"
  end

  test "a failed summarizer is reported honestly, not as 'nothing to compact' (N41)" do
    id = "compact-failed-#{System.unique_integer([:positive])}"

    start(id,
      idle_compaction_runner: fn state ->
        {%{state | compaction_backoff: 3}, {:failed, :wall_clock_exceeded}}
      end
    )

    :ok = Session.debug_gate(id, [compact_call()])

    {:ok, st} = Session.state(id)
    content = Enum.find_value(st.context.messages, fn m -> if m.role == :tool, do: text(m) end)

    assert content =~ "compaction failed"
    assert content =~ "timed out"
    refute content =~ "nothing to compact"
  end

  test "test_mode's default summarizer reports 'nothing to compact' without a provider" do
    # No runner: `compact_now/2` short-circuits in test_mode to
    # `{state, false}`, so the tool returns the honest "nothing" result and
    # the exchange still carries exactly one result for the call.
    id = "compact-nothing-#{System.unique_integer([:positive])}"
    start(id)

    :ok = Session.debug_gate(id, [compact_call()])

    {:ok, st} = Session.state(id)

    # the call has a result in the context (canonical exchange), and it says
    # nothing was compacted
    assert Enum.any?(st.context.messages, fn m ->
             m.role == :tool and text(m) =~ "nothing to compact"
           end)
  end

  test "a compact call alongside a real tool keeps both results (round stays canonical)" do
    id = "compact-mixed-#{System.unique_integer([:positive])}"

    runner = fn state ->
      summary = %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("S")]}
      {%{state | context: %{state.context | messages: [summary]}}, :changed}
    end

    start(id, idle_compaction_runner: runner, policy: CodingAgent.Core.Permissions.load(nil, nil))

    read_call = %{
      id: "r1",
      name: "read_file",
      arguments: %{"path" => Path.join(@tmp_root, "x")}
    }

    :ok = Session.debug_gate(id, [read_call, compact_call("c1")])

    {:ok, st} = Session.state(id)
    texts = Enum.map(st.context.messages, &text/1)

    # both the compact result and the read_file result are present
    assert Enum.any?(texts, &(&1 =~ "compacted"))
    assert Enum.any?(st.context.messages, &(&1.role == :tool))
  end

  test "an agent that does not advertise compact cannot use it (N45)" do
    id = "compact-fenced-#{System.unique_integer([:positive])}"

    # a policy whose `enabled` whitelist excludes `compact`: the toolset
    # narrowing means compact is NOT advertised, so the interception must
    # not run it (it used to, bypassing the toolset entirely).
    policy = %{CodingAgent.Core.Permissions.load(nil, nil) | enabled: ["read_file"]}

    runner = fn state ->
      summary = %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("S")]}
      {%{state | context: %{state.context | messages: [summary]}}, :changed}
    end

    start(id, idle_compaction_runner: runner, policy: policy)

    before = Session.state(id) |> elem(1) |> Map.get(:context) |> ReqLLM.Context.to_list()
    :ok = Session.debug_gate(id, [compact_call()])

    {:ok, st} = Session.state(id)
    after_msgs = ReqLLM.Context.to_list(st.context)

    # the context did NOT shrink, and no "compacted" result was produced
    assert length(after_msgs) >= length(before)
    refute Enum.any?(st.context.messages, &(&1.role == :tool and text(&1) =~ "compacted"))
  end

  defp text(%ReqLLM.Message{content: content}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end
end
