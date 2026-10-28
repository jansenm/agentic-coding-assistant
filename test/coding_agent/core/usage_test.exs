defmodule CodingAgent.Core.UsageTest do
  @moduledoc """
  Token accounting (sidebar + compaction): usage accumulates per turn,
  is persisted in snapshots, and drives the token-based compaction
  trigger — the provider's own last-turn input_tokens against the
  context window (chars estimates drift; provider counts are truth).
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.{State, Store, Usage}

  defmodule FakeCosts do
    # The billing-probe seam (review P38): answers from the caller's
    # process dictionary, so a test has no network and no rate limit.
    def snapshot(_model, _providers), do: Process.get(:cost_snapshot) || {:error, :no_fixture}
    def balance(_model, _providers), do: Process.get(:cost_balance) || :none
  end

  defp state do
    %State{id: "usage-test", context: ReqLLM.Context.new(), model: "m", status: :idle}
  end

  test "usage accumulates across turns; last_input_tokens tracks the latest turn" do
    s0 = state()

    s1 =
      Session.add_usage(s0, %{
        input_tokens: 100,
        output_tokens: 10,
        cached_tokens: 80,
        total_cost: 0.01
      })

    s2 =
      Session.add_usage(s1, %{
        input_tokens: 250,
        output_tokens: 40,
        cached_tokens: 200,
        total_cost: 0.02
      })

    assert s2.usage.input_tokens == 350
    assert s2.usage.output_tokens == 50
    assert s2.usage.cached_tokens == 280
    assert s2.usage.cost == 0.030000000000000002 or abs(s2.usage.cost - 0.03) < 1.0e-9
    assert s2.usage.last_input_tokens == 250
  end

  test "nil usage (provider gave none) leaves state untouched" do
    s0 = state()
    assert Session.add_usage(s0, nil) == s0
  end

  test "the sampled cost is applied to the state and the marker gates the next probe (P38)" do
    now = System.system_time(:millisecond)

    Process.put(:cost_snapshot, {:ok, %{usd: 1.20, at: now}})

    Process.put(
      :cost_balance,
      {:ok, %{remaining: 4.0, allowance: 60.0, purchased: 0.0, from: nil, until: nil}}
    )

    state = %State{
      id: "usage-cost-#{System.unique_integer([:positive])}",
      context: ReqLLM.Context.new(),
      model: "m",
      status: :idle,
      persist?: false,
      cost_module: FakeCosts,
      usage: %Usage{marker: %{usd: 1.0, at: 0}}
    }

    next = Session.add_usage(state, %{input_tokens: 10, output_tokens: 1})

    # the delta is the money spent since the previous sample — discarded
    # before, so every round looked like a first sample and no cost ever
    # appeared (the credits row did, because it is broadcast regardless)
    assert_in_delta next.usage.cost, 0.20, 1.0e-9
    assert next.usage.cost_basis == :billed
    assert next.usage.marker.usd == 1.20
    assert next.usage.balance.remaining == 4.0
    # the advanced marker is what holds the 30 s gate; without it every
    # round paid two billing HTTP reads
    refute Usage.sample_due?(next.usage, 30_000, now + 1_000)
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
    assert loaded.usage.cached_tokens == 0
    Store.delete(s.id)
  end

  # The plan_tokens/3 trigger locks live in compaction_test.exs next to
  # the other compaction locks (plan boundary, apply, the session-level
  # decide/2 decision and the task budget) — one home per concern.
end
