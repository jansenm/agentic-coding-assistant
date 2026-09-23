defmodule CodingAgent.UI.TrackBStatusTest do
  @moduledoc """
  Track B: the status lives at the input, and a silent agent is visibly
  alive.

  - `Styles.spinner/1` / `status_line/6` are pure (frame set + label).
  - The TUI declares a spinner subscription only while a turn is busy.
  - The status renders in the live band ABOVE the input field
    (`UI.LiveBand`), on the transcript's own surface, while the
    composer's meta row below the field is SETUP (the agent and model the
    next input will use).
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

  # an explicit agent (the band's identity check): `start_tui/1` takes the
  # SIZE, so the opts variant is a separate name
  defp start_tui_with(agent) do
    start_supervised!(%{
      id: String.to_atom("trackb-#{System.unique_integer([:positive])}"),
      start:
        {Tui, :start_link,
         [[name: nil, test_mode: {100, 30}, scope_root: File.cwd!(), agent: agent]]}
    })
  end

  # a project-scoped variant: agent definitions live in
  # `<scope_root>/.coding-agent/agents`
  defp start_tui_in(root, agent) do
    start_supervised!(%{
      id: String.to_atom("trackb-#{System.unique_integer([:positive])}"),
      start:
        {Tui, :start_link,
         [[name: nil, test_mode: {100, 30}, scope_root: root, sidebar: false, agent: agent]]}
    })
  end

  defp write_agent(root, filename, frontmatter) do
    dir = Path.join([root, ".coding-agent", "agents"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), frontmatter)
  end

  defp joined(pid), do: pid |> buffer() |> Enum.join("\n")

  describe "Styles.spinner/1 + status_line/6 (pure)" do
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

  describe "the live band (A)" do
    # The band's own unit tests live in live_band_test.exs; these assert
    # the TUI WIRES it — which values reach the band, and from where.

    # The row carrying `needle`. The status words are unique in the frame
    # now: the composer's meta row below the field is SETUP and paints no
    # status, so a "thinking"/"○ idle" row IS the band.
    defp row_with(pid, needle) do
      rows = buffer(pid)

      case Enum.find_index(rows, &String.contains?(&1, needle)) do
        nil -> raise "no row contains #{inspect(needle)}\n#{Enum.join(rows, "\n")}"
        i -> i
      end
    end

    # The composer's SETUP row: the LAST row naming a model (the sidebar
    # names one near the top; the composer sits at the bottom).
    defp setup_row(pid) do
      buffer(pid)
      |> Enum.with_index()
      |> Enum.filter(&String.contains?(elem(&1, 0), "model "))
      |> List.last()
      |> elem(1)
    end

    test "the status renders in the band above the field, with the running identity" do
      pid = start_tui()

      agent(pid, {:turn_started, "build"})
      agent(pid, {:status_changed, :running})

      row = Enum.at(buffer(pid), row_with(pid, "thinking"))

      # the band carries the RUNNING identity and the live status; the
      # composer's setup row below the field is a different row
      assert String.contains?(row, "agent build")
      assert String.contains?(row, Styles.spinner(sync(pid).spin))

      # no frame glyphs: neither the band nor the composer is a box
      refute String.contains?(row, "╰")
      refute String.contains?(row, "╭")

      # ...and the band sits ABOVE the composer's meta row
      assert row_with(pid, "thinking") < setup_row(pid)
    end

    test "an IDLE status is in the band too (the row is permanent)" do
      pid = start_tui()

      # idle is painted once, by the band: the setup row below the field
      # carries no status word at all
      assert Enum.at(buffer(pid), row_with(pid, "○ idle")) =~ "idle"
      refute Enum.at(buffer(pid), setup_row(pid)) =~ "idle"
    end

    test "a started tool is named in the band" do
      pid = start_tui()

      agent(pid, {:turn_started, "build"})
      agent(pid, {:status_changed, :running})
      agent(pid, {:tool_started, "mix"})

      assert sync(pid).active_tool == "mix"
      assert Enum.at(buffer(pid), row_with(pid, "running mix")) =~ "agent build"
    end

    test "tool_executed clears the running tool" do
      pid = start_tui()

      agent(pid, {:turn_started, "build"})
      agent(pid, {:status_changed, :running})
      agent(pid, {:tool_started, "mix"})
      agent(pid, {:tool_executed, "mix", "ok"})

      assert sync(pid).active_tool == nil
      refute joined(pid) =~ "running mix"
      # the band is back to the thinking word, still there
      assert joined(pid) =~ "thinking"
    end

    test "the band's identity is the RUNNING agent, not the next one" do
      pid = start_tui_with("build")

      agent(pid, {:turn_started, "build"})
      agent(pid, {:status_changed, :running})

      # Tab switches what the NEXT input will use (the composer row); the
      # running turn keeps its own agent (ADR 018) — which is the whole
      # reason the band exists
      key(pid, "tab")
      assert sync(pid).next_agent != sync(pid).running_agent

      band = Enum.at(buffer(pid), row_with(pid, "thinking"))
      setup = buffer(pid) |> Enum.at(setup_row(pid))

      assert band =~ "agent build"
      assert setup =~ sync(pid).next_agent
      refute setup =~ "agent build"
    end

    test "the band's identity goes away when the turn ends (idle repeats nothing)" do
      pid = start_tui_with("build")

      agent(pid, {:turn_started, "build"})
      agent(pid, {:status_changed, :running})
      assert Enum.at(buffer(pid), row_with(pid, "thinking")) =~ "agent build"

      agent(pid, {:status_changed, :idle})
      # idle: the setup row below the field already names the agent and
      # model, so the band carries the status alone
      assert Enum.at(buffer(pid), row_with(pid, "○ idle")) =~ "○ idle"
      refute Enum.at(buffer(pid), row_with(pid, "○ idle")) =~ "agent "
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

    test "a non-busy band never counts seconds (idle/error/pause)" do
      pid = start_tui_with("build")

      agent(pid, {:turn_started, "build"})
      agent(pid, {:status_changed, :running})
      agent(pid, {:status_changed, :idle})

      # the clock is stale by 9s, but an idle turn is not waiting on one:
      # "○ idle · 9s" would imply a countdown that no longer runs
      :sys.replace_state(pid, fn rt ->
        update_in(rt.user_state.last_activity_at, &(&1 - 9_000))
      end)

      fire(pid, :__spin__)

      idle = Enum.at(buffer(pid), row_with(pid, "○ idle"))
      assert idle =~ "○ idle"
      refute idle =~ ~r/\d+s/
    end

    test "a tool left in flight does not survive the turn that started it" do
      pid = start_tui_with("build")

      agent(pid, {:turn_started, "build"})
      agent(pid, {:status_changed, :running})
      agent(pid, {:tool_started, "mix"})

      # the result that would clear the label is never coming (a failed
      # turn); the pause/error row must not read "running mix"
      agent(pid, {:status_changed, :error, :boom})

      assert sync(pid).active_tool == nil
      refute joined(pid) =~ "running mix"
      refute joined(pid) =~ "mix"
    end

    test "the band's model follows the agent a NEW turn runs as (mid-turn Tab)" do
      # a mid-turn Tab leaves the mount-time model cache naming the OLD
      # agent; the next turn's :turn_started must resolve the model the
      # session actually put on the wire (State.effective_model/1)
      root = System.tmp_dir!() |> Path.join("trackb-#{System.unique_integer([:positive])}")
      File.rm_rf!(root)
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      write_agent(root, "alpha.md", """
      ---
      description: alpha
      mode: primary
      model: ollama:alpha-model
      ---
      alpha body
      """)

      write_agent(root, "beta.md", """
      ---
      description: beta
      mode: primary
      model: ollama:beta-model
      ---
      beta body
      """)

      pid = start_tui_in(root, "alpha")
      assert sync(pid).running_agent_model == "ollama:alpha-model"

      agent(pid, {:turn_started, "alpha"})
      agent(pid, {:status_changed, :running})

      key(pid, "tab")
      assert sync(pid).next_agent == "beta"

      # the boundary: next turn runs as beta
      agent(pid, {:status_changed, :idle})
      agent(pid, {:turn_started, "beta"})

      s = sync(pid)
      assert s.running_agent == "beta"
      assert s.running_agent_model == "ollama:beta-model"
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
