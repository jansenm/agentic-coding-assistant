defmodule CodingAgent.UI.TuiStreamBurstTest do
  @moduledoc """
  Regression: a long reasoning stream must not freeze the UI.

  Found live: the TUI rendered the full markdown transcript once per
  streaming delta. A reasoning model emits hundreds of tiny deltas, so
  typed keys and ESC sat in the mailbox behind a render train — a
  500-delta burst blocked `:sys.get_state` past five seconds (the
  interaction hang the user reported). Deltas are now coalesced
  (`drain_deltas/2`): a burst costs one render, and input is handled
  between batches.
  """
  use CodingAgent.TuiCase, async: false

  alias CodingAgent.UI.Tui

  # A generous wall-clock bound: the bug took 5s+, the fix ~30ms. The
  # margin is wide enough to never flake on a loaded CI box, yet narrow
  # enough that the per-delta render regression cannot hide.
  @burst_budget_ms 2_000

  defp start_tui do
    start_supervised!(%{
      id: :burst_tui,
      start: {Tui, :start_link, [[name: nil, test_mode: {100, 40}, scope_root: File.cwd!()]]}
    })
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
end
