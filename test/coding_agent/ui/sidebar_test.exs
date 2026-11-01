defmodule CodingAgent.UI.SidebarTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Session.{Timing, Usage}
  alias CodingAgent.UI.Sidebar

  # The panel's ORDER is a design decision (the reader's questions, top to
  # bottom), so it is asserted as one: the labels in the order they paint.
  # Rendering it here is enough — `Sidebar` reads no session, no config and
  # no clock, which is what makes this a unit test.

  defp labels(panel) do
    panel
    |> Sidebar.lines()
    |> Enum.map(&line_text/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp line_text(%ExRatatui.Text.Line{spans: spans}) do
    Enum.map_join(spans, "", & &1.content)
  end

  defp panel(opts \\ []) do
    Sidebar.new(
      Keyword.merge(
        [
          scope_root: "/work/my-repo",
          session_id: "tui-abc123",
          next_agent: "build",
          model: "ollama_cloud:glm-5.3-flash",
          usage: Usage.new(),
          width: 36
        ],
        opts
      )
    )
  end

  test "the scope heads the panel, and the hints close it" do
    lines = labels(panel())

    assert hd(lines) =~ "my-repo"
    assert List.last(lines) =~ "ctrl-x p hides panel"
  end

  test "identity comes before the figures" do
    lines = labels(panel())
    agent = Enum.find_index(lines, &(&1 =~ "agent:"))
    model = Enum.find_index(lines, &(&1 =~ "model:"))
    session = Enum.find_index(lines, &(&1 =~ "session:"))
    effort = Enum.find_index(lines, &(&1 =~ "effort:"))

    assert agent < model
    assert model < session
    assert session < effort
  end

  # The reason for the reorder: the two blocks that CHANGE while a session
  # works sit above the reference figures, not below a wall of numbers that
  # only move at a round boundary.
  test "the live blocks (subagents, todo) sit above the figures" do
    lines =
      labels(
        panel(
          subagents: %{"s1" => %{agent: "explore", model: "m", finished?: false}},
          todos: [%{"content" => "read the code", "status" => "in_progress"}]
        )
      )

    subagents = Enum.find_index(lines, &(&1 =~ "subagents"))
    todo = Enum.find_index(lines, &(&1 =~ "todo"))
    tokens_in = Enum.find_index(lines, &(&1 =~ "tokens in"))

    assert subagents < todo
    assert todo < tokens_in
  end

  # Every block that is absent says nothing at all: no header, no gap. A
  # fresh session is a short panel, not an empty scaffold.
  test "an empty session paints no subagent, todo, money or catalog block" do
    lines = labels(panel())

    refute Enum.any?(lines, &(&1 =~ "subagents"))
    refute Enum.any?(lines, &(&1 =~ "todo"))
    refute Enum.any?(lines, &(&1 =~ "cost:"))
    refute Enum.any?(lines, &(&1 =~ "credits:"))
    refute Enum.any?(lines, &(&1 =~ "catalog:"))
  end

  test "the context row carries the window share, and soft is marked assumed on a guess" do
    usage = Usage.new() |> Map.put(:last_input_tokens, 25_000)

    lines =
      labels(panel(usage: usage, window: 100_000, soft: 50_000, hard: 80_000))

    assert Enum.any?(lines, &(&1 =~ ~r/context:\s+25\.0k \(25% win\)/))
    assert Enum.any?(lines, &(&1 =~ ~r/soft at:\s+50\.0k tok$/))

    assumed =
      labels(
        panel(
          usage: usage,
          window: 100_000,
          soft: 50_000,
          hard: 80_000,
          window_source: :fallback
        )
      )

    assert Enum.any?(assumed, &(&1 =~ "tok (assumed)"))
  end

  test "the effort row reads 'default' when nothing is configured" do
    assert Enum.any?(labels(panel()), &(&1 =~ ~r/effort:\s+default/))
    assert Enum.any?(labels(panel(effort: :high)), &(&1 =~ ~r/effort:\s+high/))
  end

  test "the last round row is the provider call plus the work it caused" do
    round = %{round: 1, llm_ms: 1_000, tool_ms: 250}
    lines = labels(panel(last_round: round))

    assert Enum.any?(lines, &(&1 =~ ~r/last round:\s+1\.0 s \+ 250 ms/))
  end

  test "a running turn shows both agents, an idle one only the next" do
    idle = labels(panel(next_agent: "build"))
    assert Enum.any?(idle, &(&1 =~ ~r/agent:\s+build$/))

    running =
      labels(panel(running_agent: "build", next_agent: "plan", busy?: true))

    assert Enum.any?(running, &(&1 =~ "build running"))
    assert Enum.any?(running, &(&1 =~ "plan next"))
  end

  test "a finished subagent leaves the panel, the active tab is marked" do
    done = %{"s1" => %{agent: "explore", model: "m", finished?: true}}
    refute Enum.any?(labels(panel(subagents: done)), &(&1 =~ "subagents"))

    live = %{"s1" => %{agent: "explore", model: "m", finished?: false}}
    assert Enum.any?(labels(panel(subagents: live, active_tab: "s1")), &(&1 =~ "▸ explore"))
    assert Enum.any?(labels(panel(subagents: live)), &(&1 =~ "· explore"))
  end

  # The money rules live in ONE place (`UI.Format`) and both surfaces read
  # them; this pins the sidebar half, the `/stats` half is pinned by the
  # Format tests.
  test "money rows follow Format: no cost of 0, allowance beside the balance" do
    usage = %{Usage.new() | cost: 0.25, cost_basis: :billed, balance: %{remaining: 4.0}}
    lines = labels(panel(usage: usage))

    assert Enum.any?(lines, &(&1 =~ ~r/cost:\s+\$0\.2500 \(billed\)/))
    assert Enum.any?(lines, &(&1 =~ ~r/credits:\s+\$4\.00/))

    refute Enum.any?(labels(panel()), &(&1 =~ "cost:"))
  end

  test "the panel is one Paragraph on the sidebar fill, with no border" do
    widget = Sidebar.widget(panel())

    assert widget.block.borders == []
    assert widget.block.title == nil
  end

  test "the timing helpers agree with the type the session stores" do
    assert %Timing{} = Timing.new()
  end
end
