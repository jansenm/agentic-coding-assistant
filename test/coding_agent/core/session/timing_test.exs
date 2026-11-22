# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.TimingTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Session.Timing

  test "a round records the model time first, then the tool time" do
    timing = Timing.finish_llm(Timing.new(), 4_200)
    assert timing.last == %{round: 1, llm_ms: 4_200, tool_ms: 0}

    {timing, round} = Timing.finish_tools(timing, 600)

    assert round == %{round: 1, llm_ms: 4_200, tool_ms: 600}
    assert timing.rounds == 1
    assert timing.llm_ms == 4_200
    assert timing.tool_ms == 600
    assert timing.last == round
  end

  test "finish_tools without an open round changes nothing and broadcasts nothing" do
    timing = Timing.new()

    assert {^timing, nil} = Timing.finish_tools(timing, 900)
    assert timing.rounds == 0
    assert timing.tool_ms == 0
  end

  test "a stale last round is not re-broadcast after a turn reset" do
    {timing, _} = Timing.finish_tools(Timing.finish_llm(Timing.new(), 100), 50)
    timing = Timing.begin_turn(timing)

    assert timing.last == nil
    assert {^timing, nil} = Timing.finish_tools(timing, 900)
  end

  test "the round number counts the session, the turn counter starts over" do
    timing =
      Timing.new()
      |> Timing.finish_llm(10)
      |> Timing.begin_turn()
      |> Timing.finish_llm(20)

    assert timing.rounds == 2
    assert timing.turn_rounds == 1
    assert timing.last.round == 2
  end

  test "begin_turn resets the turn counters and keeps the session totals" do
    {timing, _} = Timing.finish_tools(Timing.finish_llm(Timing.new(), 4_200), 600)
    timing = Timing.begin_turn(timing)

    assert timing.turn_rounds == 0
    assert timing.turn_llm_ms == 0
    assert timing.turn_tool_ms == 0
    assert timing.llm_ms == 4_200
    assert timing.tool_ms == 600
    assert timing.rounds == 1
  end

  test "start/1 measures the clock when no duration is passed in" do
    timing = Timing.start(Timing.new())
    Process.sleep(5)
    timing = Timing.finish_llm(timing)
    assert timing.llm_ms >= 5

    timing = Timing.start(timing)
    Process.sleep(5)
    {_timing, round} = Timing.finish_tools(timing)
    assert round.tool_ms >= 5
  end

  test "restore/1 fills an old struct and never resurrects the in-flight stamp" do
    restored = Timing.restore(%{rounds: 3, llm_ms: 100, tool_ms: 200, started_at: 123})

    assert restored.rounds == 3
    assert restored.llm_ms == 100
    assert restored.turn_rounds == 0
    assert restored.started_at == nil

    assert Timing.restore(nil) == Timing.new()
  end

  test "format_ms names its scale" do
    assert Timing.format_ms(0) == "0 ms"
    assert Timing.format_ms(450) == "450 ms"
    assert Timing.format_ms(4_200) == "4.2 s"
    assert Timing.format_ms(192_000) == "3m 12s"
    assert Timing.format_ms(3_840_000) == "1h 04m"
  end

  test "per_round divides by the session's rounds, never by zero" do
    timing = Timing.new() |> Timing.finish_llm(100) |> Timing.finish_llm(300)

    assert Timing.per_round(timing.llm_ms, timing) == 200
    assert Timing.per_round(500, Timing.new()) == 0
  end
end
