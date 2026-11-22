# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.CLIAwaitTreeTest do
  # Review N124: `mix tui` starts the TUI from the CLI, not from the application
  # supervisor. So when the application tree dies (a crash loop
  # in a singleton child), the TUI keeps painting a screen whose store,
  # sessions and catalog are gone. `await_tui/3` now monitors the tree too:
  # it stops the TUI first (its terminate restores the terminal — a hard
  # halt would leave the alternate screen and raw mode behind), prints the
  # reason and exits non-zero.
  #
  # `capture_io(:stderr, …)` swaps the GLOBAL :standard_error device, so
  # this module must not run beside async tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CodingAgent.CLI

  test "the application tree dying stops the TUI, reports it and exits non-zero" do
    {:ok, tree} = Agent.start_link(fn -> nil end)
    # a real gen_server, so the stop in `await_tui/3` is a real stop
    {:ok, tui} = Agent.start_link(fn -> nil end)

    test_pid = self()

    halt = fn code ->
      send(test_pid, {:halted, code})
      :ok
    end

    task = Task.async(fn -> CLI.await_tui(tui, halt, tree) end)

    stderr =
      capture_io(:stderr, fn ->
        Agent.stop(tree)
        assert_receive {:halted, 1}, 1_000
        assert :ok = Task.await(task)
      end)

    assert stderr =~ "the application tree stopped (:normal)"
    assert stderr =~ "restart the TUI"
    refute Process.alive?(tui)
  end
end
