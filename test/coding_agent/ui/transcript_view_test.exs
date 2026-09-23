defmodule CodingAgent.UI.TranscriptViewTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.TranscriptView

  defp tool(id, name, content), do: {:tool, id, name, content}

  describe "height/3" do
    test "info is its wrapped line count" do
      # 1 text + 3 air
      assert TranscriptView.height({:info, "x"}, 80, nil) == 4
    end

    test "user has a border allowance" do
      # the shared agent box has no padding: 1 text row + 2 border rows
      assert TranscriptView.height({:user, "hello"}, 80, nil) == 3
    end

    test "long lines wrap by width" do
      # 200 chars at width 80 -> 3 lines inside the shared agent box
      # 3 wrap lines + 2 border rows + 3 air rows after the answer
      assert TranscriptView.height({:assistant, String.duplicate("x", 200)}, 80, nil) == 8
    end

    test "collapsed tool is one line" do
      # 1 header line + 3 air
      assert TranscriptView.height(tool("t1", "shell", "a\nb\nc"), 80, nil) == 4
    end

    test "expanded tool is content + border" do
      # header line + 3 content lines; plain paragraph, no border rows
      # "▸ shell" + 3 content lines + 2 border rows + 3 air
      assert TranscriptView.height(tool("t1", "shell", "a\nb\nc"), 80, "t1") == 9
    end
  end

  describe "viewport/5" do
    defp entries(n), do: Enum.map(1..n, &{:info, "line #{&1}"})

    test "empty" do
      assert TranscriptView.viewport([], 5, 0, 80, false) == {0, []}
    end

    # every info entry occupies 4 rows (1 text + 3 air). The viewport
    # returns the clamped offset plus PANE-RELATIVE positions (ADR 028):
    # 0 is the pane's first row, negative means the entry starts above it.
    test "follow mode: the tail is visible at offset 0" do
      {clamped, selected} = TranscriptView.viewport(entries(10), 3, 0, 80, false)
      assert clamped == 0
      # the last entry's top is one row above the pane's bottom edge
      assert selected == [{{:info, "line 10"}, -1, 4}]
    end

    test "offset scrolls up: the window moves toward the head" do
      {clamped, selected} = TranscriptView.viewport(entries(10), 3, 5, 80, false)
      assert clamped == 5
      # 40 lines total, pane 3, offset 5 -> the pane shows lines 32..34.
      # Entry 9 spans lines 32..35, so it is the one at the pane top
      # (rel 0); entry 10 spans 36..39 and is below the pane.
      assert selected == [{{:info, "line 9"}, 0, 4}]
    end

    test "clamped at the top: cannot scroll above line 0" do
      # the walk reaches the head, so the total (40 lines) is known and
      # the offset clamps to total - height = 37
      {clamped, _} = TranscriptView.viewport(entries(10), 3, 999, 80, false)
      assert clamped == 37
    end

    test "partial entries at the edges are included" do
      # measured heights drive the viewport: the markdown entry is
      # measured (not estimated — markdown paragraph spacing changes
      # rendered line counts), so derive the expectation from the same
      # measurement
      big = {:assistant, "x\n\nx\n\nx\n\nx\n\nx\n\nx\n\nx\n\nx"}
      entries = [{:info, "a"}, big, {:info, "b"}]

      big_h = TranscriptView.height(big, 80, nil)
      info_h = TranscriptView.height({:info, "a"}, 80, nil)
      total = info_h + big_h + info_h

      # offset 8 (in range: total - 4 > 8), pane 4 -> pane top line 16,
      # which falls INSIDE the big entry (it spans 4..4+big_h): the big
      # entry is clipped on both edges and is the only visible one
      {clamped, selected} = TranscriptView.viewport(entries, 4, 8, 80, false)
      assert clamped == 8

      pane_top = total - 4 - 8
      # the big entry starts 12 lines above the pane top (negative rel)
      assert selected == [{big, info_h - pane_top, big_h}]
    end

    test "short content sits at the pane TOP, not floating at the bottom" do
      # Regression (found by the accordion hit-test): when the transcript
      # is shorter than the pane it is top-anchored, so the FIRST entry
      # starts at pane row 0 — hit-testing depends on it. (The pane still
      # shows the content's last lines when they overflow the bottom.)
      entries = [{:info, "a"}, {:info, "b"}]

      # a 9-row pane fits both (8 rows): first entry at pane top
      {clamped, selected} = TranscriptView.viewport(entries, 9, 0, 80, false)
      assert clamped == 0
      assert List.first(selected) == {{:info, "a"}, 0, 4}
      assert List.last(selected) == {{:info, "b"}, 4, 4}
    end

    test "only the tail is measured: entries above the window are untouched" do
      # A window far from the head must not walk the whole list. The
      # 10th-from-last entry never appears when the pane covers 3 rows
      # from the tail — so a lazy call returns without measuring it.
      # (The observable contract is the SELECTED set; the cost claim is
      # the ADR 028 benchmark.)
      {clamped, selected} = TranscriptView.viewport(entries(1000), 3, 0, 80, false)
      assert clamped == 0
      assert length(selected) == 1
    end
  end

  describe "differential: the lazy walk == the eager algorithm it replaced" do
    # ADR 028 decision 5 keeps `total_height/3` as the eager TEST
    # primitive precisely so this test can exist: it reconstructs the
    # old whole-transcript algorithm (absolute cursor from the HEAD,
    # `top = total - height - offset`) and asserts the lazy tail-first
    # walk produces the same selected entries, pane-relative positions
    # and clamp across offsets, pane sizes and content shorter than the
    # pane. Without a caller the function is dead weight; with one it is
    # the anchor that catches a silent divergence in the hot path.
    defp eager_viewport(entries, height, offset, width, open_id) do
      total = TranscriptView.total_height(entries, width, open_id)
      clamped = min(offset, max(total - height, 0))
      top = max(total - height - offset, 0)

      {selected, _} =
        entries
        |> Enum.map_reduce(0, fn entry, cursor ->
          h = TranscriptView.height(entry, width, open_id)
          {{entry, cursor, h}, cursor + h}
        end)

      selected =
        selected
        |> Enum.filter(fn {_e, c, h} -> c < top + height and c + h > top end)
        |> Enum.map(fn {e, c, h} -> {e, c - top, h} end)

      {clamped, selected}
    end

    defp mixed_entries do
      [
        {:info, "a note"},
        {:user, "hey", "build"},
        {:assistant, "answer one\n\nwith two paragraphs", "build"},
        {:reasoning, "some thinking text that wraps around the pane width"},
        tool("t1", "shell", "line1\nline2\nline3"),
        tool("t2", "read_file", "contents"),
        {:info, "a longer info line that could wrap at a narrow width"},
        {:assistant, String.duplicate("x ", 120), "plan"},
        {:user, "again"},
        {:info, "tail"}
      ]
    end

    test "identical entries, pane-relative positions and clamps across offsets" do
      entries = mixed_entries()

      for width <- [40, 80],
          pane <- [3, 9, 24],
          offset <- [0, 1, 7, 50, 500, 99_999] do
        {eager_clamped, eager_selected} = eager_viewport(entries, pane, offset, width, nil)
        {lazy_clamped, lazy_selected} = TranscriptView.viewport(entries, pane, offset, width, nil)

        assert eager_clamped == lazy_clamped,
               "clamp differs at width=#{width} pane=#{pane} offset=#{offset}"

        assert eager_selected == lazy_selected,
               "selection differs at width=#{width} pane=#{pane} offset=#{offset}"
      end
    end

    test "identical for content SHORTER than the pane (the top-anchor case)" do
      entries = [{:info, "a"}, {:info, "b"}]

      for pane <- [9, 24],
          offset <- [0, 5, 99_999] do
        assert eager_viewport(entries, pane, offset, 80, nil) ==
                 TranscriptView.viewport(entries, pane, offset, 80, nil)
      end
    end

    test "identical with an expanded tool (an open_id changes measured heights)" do
      entries = mixed_entries()

      for open <- [nil, "t1", "t2"],
          pane <- [4, 12],
          offset <- [0, 3, 40] do
        assert eager_viewport(entries, pane, offset, 80, open) ==
                 TranscriptView.viewport(entries, pane, offset, 80, open)
      end
    end
  end

  describe "bound_letters + toggle (5c wiring)" do
    test "toggle_tool_output is a keymap binding" do
      km = CodingAgent.UI.Keymap.defaults()
      assert CodingAgent.UI.Keymap.resolve(km, %{key: :ctrl_t, mod: :none}) == :toggle_tool_output
    end
  end
end
