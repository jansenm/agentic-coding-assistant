# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.TabsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.{Tabs, Tabs.Child}

  # The tab slice, asserted without a terminal: `UI.Tabs` reads no clock and
  # no session state, so what a tab SHOWS and which view is active are plain
  # functions of the values handed in. The TUI's own integration tests
  # (`tui_subagent_test.exs`) pin the routing through the real key path; this
  # file pins the contract those routes rely on.

  defp line_text(%ExRatatui.Text.Line{spans: spans}) do
    Enum.map_join(spans, "", & &1.content)
  end

  defp labels(%Tabs{} = tabs) do
    tabs
    |> Tabs.tab_line()
    |> line_text()
    |> String.split("  ", trim: true)
    |> Enum.map(&String.trim/1)
  end

  # -- the pointer (F4) ------------------------------------------------------

  test "no children reads as the primary view" do
    tabs = Tabs.new()

    assert Tabs.empty?(tabs)
    assert Tabs.active_child(tabs) == nil
    assert Tabs.active_id(tabs) == nil
    assert Tabs.tab_line(tabs) == nil
  end

  test "the pointer names a tab, and a tab that no longer exists reads as the primary" do
    tabs =
      Tabs.new()
      |> Tabs.start("c1", "explore", "m")
      |> Tabs.start("c2", "reviewer", "m")

    assert {"c1", %Child{agent: "explore", model: "m"}} = Tabs.active_child(Tabs.open(tabs, "c1"))

    # the lifetime case: the pointed-at tab is gone, the pointer still names
    # it. Every consumer reads the SAME answer (`nil` = the parent view),
    # which is what makes this one rule instead of a per-consumer fallback.
    stale = %{Tabs.open(tabs, "c2") | subagents: %{"c1" => tabs.subagents["c1"]}}

    assert Tabs.active_child(stale) == nil
    assert Tabs.active_id(stale) == nil
    assert Tabs.scroll_offset(stale) == 0
    assert Tabs.open_tool_id(stale) == nil
    # ...and the tab bar marks the PARENT as viewing (the effective pointer)
    assert "[primary]" in labels(stale)
  end

  # -- every view keeps its own position -------------------------------------

  test "scrolling one view never moves another" do
    tabs =
      Tabs.new()
      |> Tabs.start("c1", "explore", "m")
      |> Tabs.open("c1")
      |> Tabs.put_scroll(40)
      |> Tabs.put_open("tool-1")
      |> Tabs.open(nil)
      |> Tabs.put_scroll(7)

    # the primary view's position
    assert Tabs.scroll_offset(tabs) == 7
    assert Tabs.open_tool_id(tabs) == nil

    # ...and the child tab kept the position it had when it went out of sight
    c1 = %{tabs | active: "c1"}
    assert Tabs.scroll_offset(c1) == 40
    assert Tabs.open_tool_id(c1) == "tool-1"
  end

  test "a new turn puts the PRIMARY view back on the tail" do
    tabs =
      Tabs.new()
      |> Tabs.start("c1", "explore", "m")
      |> Tabs.open("c1")
      |> Tabs.put_scroll(12)
      |> Tabs.open(nil)

    assert Tabs.scroll_offset(Tabs.at_tail(tabs)) == 0
    # a child tab's own position is untouched by a parent turn
    assert Tabs.scroll_offset(%{Tabs.at_tail(tabs) | active: "c1"}) == 12
  end

  # -- a child's lifetime ----------------------------------------------------

  test "a started child gets an empty, open tab" do
    tabs = Tabs.start(Tabs.new(), "c1", "explore", "m")

    assert %Child{agent: "explore", model: "m", finished?: false, transcript: [], stream: []} =
             tabs.subagents["c1"]

    # starting a child does NOT move the human's view (owner decision
    # 2026-09-30: the band and the pane follow what is LOOKING AT, not the
    # newest background job)
    assert Tabs.active_id(tabs) == nil
  end

  test "a finished child is kept, read-only, and its error is in its OWN view" do
    tabs =
      Tabs.new()
      |> Tabs.start("c1", "explore", "m")
      |> Tabs.fold("c1", {:reasoning_deltas, "weighing the options"})
      |> Tabs.finish("c1", :error)

    child = tabs.subagents["c1"]

    # a child that died never emitted `llm_message`: the stranded reasoning is
    # committed instead of being left as an in-flight block that never resolves
    assert [{:reasoning, text} | _] = child.transcript
    assert text =~ "weighing the options"
    assert Enum.any?(child.transcript, &match?({:info, _}, &1))
    assert child.stream == []
    assert child.finished?
  end

  test "finishing a tab that is not there is a no-op" do
    tabs = Tabs.new()
    assert Tabs.finish(tabs, "ghost", :ok) == tabs
  end

  # -- folding a child's events ---------------------------------------------

  test "deltas and answers land in the tab's own transcript" do
    tabs =
      Tabs.new()
      |> Tabs.start("c1", "explore", "m")
      |> Tabs.fold("c1", {:llm_deltas, "the "})
      |> Tabs.fold("c1", {:llm_deltas, "answer"})
      |> Tabs.fold("c1", {:llm_message, "the answer"})

    assert tabs.subagents["c1"].transcript == [{:assistant, "the answer"}]
    assert tabs.subagents["c1"].stream == []
  end

  test "a tool result commits the stream above it and opens nothing" do
    tabs =
      Tabs.new()
      |> Tabs.start("c1", "explore", "m")
      |> Tabs.fold("c1", {:reasoning_deltas, "thinking"})
      |> Tabs.fold("c1", {:tool_executed, "shell", "out", ["ls"]})

    child = tabs.subagents["c1"]

    assert [{:reasoning, _}, {:tool, id, "shell", "out"}] = child.transcript
    assert is_binary(id)
    assert child.open_tool_id == nil
  end

  test "the events that are not part of the reading view are ignored, not guessed at" do
    tabs = Tabs.new() |> Tabs.start("c1", "explore", "m")

    for event <- [{:status_changed, :running}, {:usage, %{}}, {:tool_started, "shell", %{}}] do
      assert Tabs.fold(tabs, "c1", event).subagents["c1"] == tabs.subagents["c1"]
    end
  end

  test "any_stream? sees a child's unpainted stream" do
    tabs = Tabs.new() |> Tabs.start("c1", "explore", "m")
    refute Tabs.any_stream?(tabs)
    assert Tabs.any_stream?(Tabs.fold(tabs, "c1", {:llm_deltas, "x"}))
  end

  # -- what the surfaces show ------------------------------------------------

  test "the tab bar names the primary, the running children and the counts" do
    tabs =
      Tabs.new()
      |> Tabs.start("c1", "explore", "m")
      |> Tabs.start("c2", "reviewer", "m")
      |> Tabs.start("c3", "archivist", "m")
      |> Tabs.finish("c3", :ok)

    assert labels(tabs) == ["[primary]", "explore", "reviewer", "+1 finished"]

    # the viewed tab is the bracketed one
    assert ["primary", "[explore]", "reviewer", "+1 finished"] ==
             labels(Tabs.open(tabs, "c1"))
  end

  test "the tab bar is bounded: the running count is named, never dropped" do
    tabs =
      Enum.reduce(1..8, Tabs.new(), fn i, tabs ->
        Tabs.start(tabs, "c#{i}", "agent#{i}", "m")
      end)

    labels = labels(tabs)
    # primary + the cap of five, and the three that did not fit are counted
    assert length(labels) == 1 + 5 + 1
    assert List.last(labels) == "+3 running"
  end

  test "the popup lists the primary first, running children before finished ones" do
    tabs =
      Tabs.new()
      |> Tabs.start("c1", "explore", "m")
      |> Tabs.start("c2", "reviewer", "m")
      |> Tabs.finish("c1", :ok)
      |> Tabs.open("c2")

    assert [
             %{id: {:tab, nil}, label: "primary transcript"},
             %{id: {:tab, "c2"}, label: c2},
             %{id: {:tab, "c1"}, label: c1}
           ] = Tabs.popup_items(tabs)

    # the row the human is IN says so, and a finished tab says that instead
    assert c2 =~ "reviewer · m (viewing)"
    assert c1 =~ "explore · m (finished)"
  end
end
