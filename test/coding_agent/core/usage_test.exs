defmodule CodingAgent.Core.UsageTest do
  @moduledoc """
  Token accounting (sidebar + compaction): usage accumulates per turn,
  is persisted in snapshots, and drives the token-based compaction
  trigger — the provider's own last-turn input_tokens against the
  context window (chars estimates drift; provider counts are truth).
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.{State, Store}

  defp state do
    %State{id: "usage-test", context: ReqLLM.Context.new(), model: "m", status: :idle}
  end

  test "usage accumulates across turns; last_input_tokens tracks the latest turn" do
    s0 = state()

    s1 =
      Session.add_usage(s0, %{input_tokens: 100, output_tokens: 10, total_cost: 0.01})

    s2 =
      Session.add_usage(s1, %{input_tokens: 250, output_tokens: 40, total_cost: 0.02})

    assert s2.usage.input_tokens == 350
    assert s2.usage.output_tokens == 50
    assert s2.usage.cost == 0.030000000000000002 or abs(s2.usage.cost - 0.03) < 1.0e-9
    assert s2.usage.last_input_tokens == 250
  end

  test "nil usage (provider gave none) leaves state untouched" do
    s0 = state()
    assert Session.add_usage(s0, nil) == s0
  end

  test "usage persists in the snapshot and survives load (old snapshots get defaults)" do
    s = %State{
      id: "usage-persist-#{System.unique_integer([:positive])}",
      context: ReqLLM.Context.new(),
      model: "m",
      status: :idle,
      usage: %{input_tokens: 1234, output_tokens: 56, last_input_tokens: 1000, cost: 0.5}
    }

    Store.save(s)
    {:ok, loaded} = Store.load(s.id)

    assert loaded.usage.input_tokens == 1234
    assert loaded.usage.last_input_tokens == 1000
    Store.delete(s.id)
  end

  # The plan_tokens/3 trigger locks live in compaction_test.exs next to
  # the other compaction locks (plan boundary, apply, the session-level
  # decide/2 decision and the task budget) — one home per concern.
end
