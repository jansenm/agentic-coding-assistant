# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.TuiStreamBurstTest do
  @moduledoc """
  Regression: a long reasoning/answer stream must stay INTERACTIVE.

  Found live: the TUI rendered the full markdown transcript once per
  streaming delta. A reasoning model emits hundreds of tiny deltas, so
  typed keys and ESC sat in the mailbox behind a render train — a
  500-delta burst blocked `:sys.get_state` past five seconds.

  The first fix (`drain_deltas/2`) folded queued deltas with a mailbox
  `receive … after 0` loop, but that still starved input on a *steady
  trickle* (the `after 0` rarely fires while deltas keep arriving). The
  current design DEFERS the render entirely: a delta folds the text and
  returns `render?: false`; a fixed-cadence subscription paints at most
  one frame per window. These tests assert the properties that matter:

    1. a delta does NOT render synchronously (the deferred contract);
    2. the stream is painted by its throttle tick, not per delta;
    3. a key is handled WHILE deltas keep arriving (mid-stream), not only
       after the stream ends.
  """
  use CodingAgent.TuiCase, async: false

  alias CodingAgent.UI.Tui
  alias ExRatatui.Subscription

  # Generous wall-clock bounds: the bug took seconds, the fix is single
  # milliseconds. Wide enough to never flake on a loaded CI box, narrow
  # enough that a render train per delta cannot hide.
  @burst_budget_ms 2_000
  @key_budget_ms 500

  defp start_tui do
    start_supervised!(%{
      id: :burst_tui,
      start: {Tui, :start_link, [[name: nil, test_mode: {100, 40}, scope_root: File.cwd!()]]}
    })
  end

  test "a delta defers its render; the throttle tick paints it" do
    pid = start_tui()

    send(pid, {:agent, {:reasoning_deltas, "deferred thought"}})
    st = sync(pid)

    # the buffer folded the delta...
    assert st.stream == [{:reasoning, "deferred thought"}]
    assert st.stream_dirty? == true

    # ...but painted nothing yet (test_mode disables the poll loop, so the
    # only writer of a frame is the throttle)
    refute Enum.any?(buffer(pid), &String.contains?(&1, "deferred thought"))

    # In PRODUCTION the throttle is declared while dirty and only while
    # dirty. The test instance runs under test_mode (no timer armed), so
    # assert the declaration against a production-shaped state.
    prod = %{st | test_mode?: false}

    assert [%Subscription{id: :stream_render, kind: :interval, interval_ms: 60}] =
             Tui.subscriptions(prod)

    assert Tui.subscriptions(%{prod | stream_dirty?: false}) == []
    assert Tui.subscriptions(%{prod | stream: []}) == []

    # the tick paints and clears the dirty flag, retiring the subscription
    fire(pid, :__stream_render__)
    assert Enum.any?(buffer(pid), &String.contains?(&1, "deferred thought"))
    assert sync(pid).stream_dirty? == false
  end

  test "a reasoning burst is absorbed without blocking input" do
    pid = start_tui()

    chunks = for i <- 1..500, do: "reasoning line #{i} with a few words\n"

    {flood_us, _} =
      :timer.tc(fn ->
        Enum.each(chunks, fn c -> send(pid, {:agent, {:reasoning_deltas, c}}) end)
        # barrier: returns only after every queued delta is handled
        :sys.get_state(pid)
      end)

    assert div(flood_us, 1000) < @burst_budget_ms,
           "a 500-delta reasoning burst took #{div(flood_us, 1000)}ms (expected < #{@burst_budget_ms}ms)"

    # the buffer folded every delta IN ORDER (coalescing must not drop or
    # reorder text)
    [{:reasoning, text}] = sync(pid).stream
    assert String.starts_with?(text, "reasoning line 1 ")
    assert String.contains?(text, "reasoning line 500 ")

    # and the UI is interactive again: the key reaches the textarea
    key(pid, "a")
    assert ExRatatui.textarea_get_value(sync(pid).textarea) == "a"
  end

  test "a key is handled WHILE deltas keep arriving (mid-stream)" do
    pid = start_tui()

    # a realistic steady trickle: one delta every 2ms, well past the time
    # a single delta takes to fold. The producer runs concurrently with
    # the key.
    parent = self()

    producer =
      spawn(fn ->
        Enum.each(1..400, fn i ->
          send(pid, {:agent, {:reasoning_deltas, "live thought #{i} more words\n"}})
          Process.sleep(2)
        end)

        send(parent, :produced)
      end)

    # inject keys WHILE the trickle runs and measure each round-trip; a
    # synchronous call can only return once the earlier deltas are folded
    # (cheap) and the key handled — never behind a full render each.
    samples =
      for _ <- 1..5 do
        {us, _} = :timer.tc(fn -> key(pid, "x") end)
        Process.sleep(20)
        div(us, 1000)
      end

    refute_received :produced
    Process.exit(producer, :kill)

    max = Enum.max(samples)

    assert max < @key_budget_ms,
           "a key during a stream took #{max}ms (samples #{inspect(samples)}), expected < #{@key_budget_ms}ms"

    # every injected key landed, in order
    assert ExRatatui.textarea_get_value(sync(pid).textarea) == "xxxxx"
  end
end
