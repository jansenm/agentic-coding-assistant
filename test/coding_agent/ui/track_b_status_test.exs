defmodule CodingAgent.UI.TrackBStatusTest do
  @moduledoc """
  Track B: the status lives at the input, and a silent agent is visibly
  alive.

  - `Styles.spinner/1` / `status_line/5` are pure (frame set + label).
  - The TUI declares a spinner subscription only while a turn is busy.
  - The status badge + spinner render on the input box's TOP-RIGHT border.
  - `{:tool_started, name}` names the running tool; silence shows a
    duration so a stuck turn diverges from a healthy one.
  - The scroll diagnostics are developer output, hidden until ctrl-x d.
  """
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.{Styles, Tui}

  defp start_tui(size \\ {100, 30}) do
    start_supervised!(%{
      id: String.to_atom("trackb-#{System.unique_integer([:positive])}"),
      start: {Tui, :start_link, [[name: nil, test_mode: size, scope_root: File.cwd!()]]}
    })
  end

  defp joined(pid), do: pid |> buffer() |> Enum.join("\n")

  describe "Styles.spinner/1 + status_line/5 (pure)" do
    test "spinner cycles by remainder and accepts nil" do
      assert Styles.spinner(nil) == Styles.spinner(0)
      assert Styles.spinner(0) != Styles.spinner(1)
      # wraps at the frame count
      assert Styles.spinner(Styles.spinner_frames()) == Styles.spinner(0)
    end

    test "busy? is true only for running/interrupting" do
      assert Styles.busy?(:running)
      assert Styles.busy?(:interrupting)
      refute Styles.busy?(:idle)
      refute Styles.busy?(:interrupted)
      refute Styles.busy?(:error)
    end

    test "status_line shows a spinner while busy, the badge glyph otherwise" do
      busy = Styles.status_line(:running, false, 3, nil)
      idle = Styles.status_line(:idle, false, nil, nil)

      busy_text = Enum.map_join(busy.spans, "", & &1.content)
      idle_text = Enum.map_join(idle.spans, "", & &1.content)

      assert busy_text =~ Styles.spinner(3)
      refute busy_text =~ "●"
      assert idle_text =~ "○"
    end

    test "status_line appends the elapsed seconds and honours a label override" do
      line = Styles.status_line(:running, false, 0, 12, "running mix")
      text = Enum.map_join(line.spans, "", & &1.content)
      assert text =~ "running mix"
      assert text =~ " · 12s"
    end
  end

  describe "spinner subscription lifecycle" do
    test "declared only while busy (production), not under test_mode" do
      pid = start_tui()
      st = sync(pid)

      # test_mode never arms a timer, so the declaration is asserted on a
      # production-shaped state (the stream throttle does the same)
      prod_idle = %{st | test_mode?: false, status: :idle}
      assert Tui.subscriptions(prod_idle) == []

      prod_running = %{st | test_mode?: false, status: :running}
      subs = Tui.subscriptions(prod_running)
      assert Enum.any?(subs, &(&1.id == :spinner))

      # the tick advances the frame; idle stops declaring it
      assert [%ExRatatui.Subscription{id: :spinner, interval_ms: 120}] =
               Enum.filter(subs, &(&1.id == :spinner))
    end

    test "the tick advances the spin counter" do
      pid = start_tui()
      before = Map.get(sync(pid), :spin, 0)
      fire(pid, :__spin__)
      assert sync(pid).spin == before + 1
    end
  end

  describe "status at the input (A)" do
    test "the status renders on the composer's identity row, right-aligned" do
      pid = start_tui()

      agent(pid, {:turn_started, "build"})
      agent(pid, {:status_changed, :running})

      rows = buffer(pid)

      # ONE row carries both halves: identity (left) and status (right)
      # (the LAST "model " row is the composer's meta row)
      footer = rows |> Enum.filter(&String.contains?(&1, "model ")) |> List.last()
      assert footer != nil
      assert String.contains?(footer, "thinking")
      assert String.contains?(footer, Styles.spinner(sync(pid).spin))
      # no frame glyphs: the composer is a filled field, not a box
      refute String.contains?(footer, "╰")
      refute String.contains?(footer, "╭")
    end

    test "a started tool is named in the status" do
      pid = start_tui()

      agent(pid, {:turn_started, "build"})
      agent(pid, {:status_changed, :running})
      agent(pid, {:tool_started, "mix"})

      assert sync(pid).active_tool == "mix"
      assert joined(pid) =~ "running mix"
    end

    test "tool_executed clears the running tool" do
      pid = start_tui()

      agent(pid, {:turn_started, "build"})
      agent(pid, {:status_changed, :running})
      agent(pid, {:tool_started, "mix"})
      agent(pid, {:tool_executed, "mix", "ok"})

      assert sync(pid).active_tool == nil
      refute joined(pid) =~ "running mix"
    end

    test "activity resets the silence clock" do
      pid = start_tui()

      # a fresh turn has no clock yet
      assert sync(pid).last_activity_at == nil

      agent(pid, {:turn_started, "build"})
      agent(pid, {:status_changed, :running})
      assert is_integer(sync(pid).last_activity_at)

      before = sync(pid).last_activity_at
      # a later delta moves the clock forward (monotonic ms; on Linux the
      # epoch is negative, so only the ORDERING is meaningful)
      agent(pid, {:reasoning_deltas, "thinking…"})
      assert sync(pid).last_activity_at >= before
    end
  end

  describe "debug line (D)" do
    test "scroll diagnostics are hidden by default, shown after ctrl-x d" do
      pid = start_tui()
      refute joined(pid) =~ "scroll:"

      # ctrl-x then d (the menu fast path)
      key(pid, "x", ["ctrl"])
      key(pid, "d")

      assert sync(pid).debug_visible? == true
      assert joined(pid) =~ "scroll:"
    end
  end
end
