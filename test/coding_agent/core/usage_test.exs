defmodule CodingAgent.Core.UsageTest do
  @moduledoc """
  Token accounting (sidebar + compaction): usage accumulates per turn,
  is persisted in snapshots, and drives the token-based compaction
  trigger — the provider's own last-turn input_tokens against the
  context window (chars estimates drift; provider counts are truth).
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.{Compaction, Session}
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

  describe "plan_tokens/3" do
    test ":none below the trigger" do
      ctx = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))
      assert Compaction.plan_tokens(ctx, 100_000, 500_000) == :none
    end

    test "compacts at 70% of the window" do
      ctx = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))

      # 70% of 500k = 350k: 350_000 * 100 > 500_000 * 70 is false (equal), 351k exceeds
      assert Compaction.plan_tokens(ctx, 350_000, 500_000) == :none
      assert {:ok, _old, _keep} = Compaction.plan_tokens(ctx, 351_000, 500_000)
    end

    test "no usage data (0) never triggers" do
      ctx = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))
      assert Compaction.plan_tokens(ctx, 0, 500_000) == :none
    end
  end
end
