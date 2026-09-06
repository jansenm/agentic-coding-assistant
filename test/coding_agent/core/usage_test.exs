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

    test "compacts at the absolute threshold, not a window percentage" do
      ctx = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))

      # the opencode lesson: an absolute trigger (default 180k) — a big
      # window must NOT push compaction later
      assert Compaction.plan_tokens(ctx, 179_999, 180_000) == :none
      assert {:ok, _old, _keep} = Compaction.plan_tokens(ctx, 180_000, 180_000)
      # 300k context with a 500k window still compacts (the %-trigger
      # would have waited for 350k — exactly the failure mode being fixed)
      assert {:ok, _old, _keep} = Compaction.plan_tokens(ctx, 300_000, 180_000)
    end

    test "no usage data (0) never triggers" do
      ctx = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))
      assert Compaction.plan_tokens(ctx, 0, 500_000) == :none
    end
  end

  describe "warn_approaching_compaction/2" do
    test "warns once at 80% of the trigger" do
      s0 = state() |> Session.add_usage(%{input_tokens: 150_000, last_input_tokens: 150_000})
      # 150k >= 144k (80% of 180k) -> warns
      s1 = Session.warn_approaching_compaction(s0, 180_000)
      assert s1.compaction_warned == true

      # second call: no double warn
      s2 = Session.warn_approaching_compaction(s1, 180_000)
      assert s2 == s1
    end

    test "does not warn below 80%" do
      s0 = state() |> Session.add_usage(%{input_tokens: 100_000, last_input_tokens: 100_000})
      s1 = Session.warn_approaching_compaction(s0, 180_000)
      assert s1.compaction_warned == false
    end
  end
end
