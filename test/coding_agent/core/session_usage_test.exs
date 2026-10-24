defmodule CodingAgent.Core.Session.UsageTest do
  @moduledoc """
  The Usage struct is the one home for the accounting rule and defaults
  (P3). These are pure and LLM-free; the session-level accumulation is
  exercised in `usage_test.exs` and `compaction_test.exs`.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Session.Usage

  test "new/0 is the single zero default" do
    assert Usage.new() == %Usage{
             input_tokens: 0,
             output_tokens: 0,
             cached_tokens: 0,
             last_input_tokens: 0,
             cost: nil
           }
  end

  test "from_map/1 heals a legacy map, a struct and nil" do
    legacy = %{input_tokens: 100, output_tokens: 5, last_input_tokens: 90, cost: 0.1}

    assert Usage.from_map(legacy) ==
             %Usage{input_tokens: 100, output_tokens: 5, last_input_tokens: 90, cost: 0.1}

    assert Usage.from_map(nil) == Usage.new()

    s = %Usage{input_tokens: 1}
    assert Usage.from_map(s) == s
  end

  test "a missing key in a legacy map defaults (no KeyError)" do
    # an old snapshot map carried only input/output/cost
    assert Usage.from_map(%{input_tokens: 7, output_tokens: 3, cost: nil}) ==
             %Usage{input_tokens: 7, output_tokens: 3, last_input_tokens: 0, cost: nil}
  end

  test "add/2 accumulates and tracks the last turn's input" do
    u1 = Usage.add(Usage.new(), %{input_tokens: 100, output_tokens: 10, total_cost: 0.01})
    u2 = Usage.add(u1, %{input_tokens: 250, output_tokens: 40, total_cost: 0.02})

    assert u2.input_tokens == 350
    assert u2.output_tokens == 50
    assert u2.last_input_tokens == 250
    assert abs(u2.cost - 0.03) < 1.0e-9
  end

  test "a nil/zero input count does NOT clobber last_input_tokens" do
    # the honesty rule: a resumed/failed turn must not re-arm the chars
    # fallback by zeroing the only sound compaction measure
    u = Usage.add(Usage.new(), %{input_tokens: 50_000, output_tokens: 1, total_cost: nil})
    assert u.last_input_tokens == 50_000

    u2 = Usage.add(u, %{input_tokens: 0, output_tokens: 0, total_cost: nil})
    assert u2.last_input_tokens == 50_000

    assert Usage.add(u, nil).last_input_tokens == 50_000
  end

  test "nil usage is a no-op" do
    u = %Usage{input_tokens: 9}
    assert Usage.add(u, nil) == u
  end

  test "last_input_tokens/1 reads through the normalizer" do
    assert Usage.last_input_tokens(nil) == 0
    assert Usage.last_input_tokens(%{input_tokens: 1, last_input_tokens: 42}) == 42
    assert Usage.last_input_tokens(%Usage{last_input_tokens: 7}) == 7
  end

  test "cached_tokens accumulates from the provider's canonical field" do
    u1 = Usage.add(Usage.new(), %{input_tokens: 1_000, cached_tokens: 800, output_tokens: 5})
    u2 = Usage.add(u1, %{input_tokens: 2_000, cached_tokens: 1_500, output_tokens: 7})

    assert u2.input_tokens == 3_000
    assert u2.cached_tokens == 2_300
    # a turn without the key (a provider that does not report caching) adds 0
    assert Usage.add(u2, %{input_tokens: 10, output_tokens: 1}).cached_tokens == 2_300
  end

  test "cached_tokens is a subset of input_tokens, and its ratio is the cache hit rate" do
    u = Usage.add(Usage.new(), %{input_tokens: 1_000, cached_tokens: 250, output_tokens: 5})

    assert Usage.cached_tokens(u) == 250
    assert_in_delta Usage.cache_hit_ratio(u), 0.25, 1.0e-9
    # readers heal a legacy map that never had the field
    assert Usage.cached_tokens(%{input_tokens: 10}) == 0
  end

  test "cache_hit_ratio/1 is nil when it would lie, not 0 or above 1" do
    # nothing counted yet: a ratio of nothing is not "0 %"
    assert Usage.cache_hit_ratio(Usage.new()) == nil
    assert Usage.cache_hit_ratio(nil) == nil
    # Anthropic reports cache reads as a SEPARATE bucket, so cached can
    # exceed input; a naive division would claim >100 % cached
    assert Usage.cache_hit_ratio(%{input_tokens: 100, cached_tokens: 900}) == nil
  end
end
