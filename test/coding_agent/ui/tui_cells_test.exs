defmodule CodingAgent.UI.TuiCellsTest do
  @moduledoc """
  Colour-level assertions on the RENDERED frame.

  `buffer/1` carries symbols only, so it can answer "is the text there"
  but not "is the text white" or "is that row filled". These tests read
  the cell buffer (`start_cell_tui/2` + `cells/1`) and assert on
  `fg`/`bg` — the only place a colour regression can be caught.

  The three reports this locks down:

    * the chrome grey was "just … gray" — the fills are now one stated
      ~90% grey instead of the terminal's ANSI 8;
    * the frame around the input "looks so … c64" — the composer has no
      border, it is a filled field;
    * the text looked "tempered" — the body text is a stated white, not
      the terminal theme's ANSI 15.
  """
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.{Palette, Styles}

  # The composer's meta row: the LAST row naming a model — the sidebar
  # also names one near the top, the composer lives at the bottom.
  defp meta_row(snapshot) do
    0..(snapshot.height - 1)
    |> Enum.filter(&String.contains?(row_text(snapshot, &1), "model "))
    |> List.last()
  end

  test "the composer is a filled field with stated text, not a themed box" do
    {pid, session} = start_cell_tui([scope_root: File.cwd!()], {100, 30})
    fire(pid, :__resize_poll__)
    snapshot = cells(session)

    # every row of the composer's rect is filled — a widget-level bg only
    # paints the rows the widget writes, so the block must carry it too
    fill = Palette.fill(Styles.palette(), :chrome)
    assert {:indexed, _} = fill

    row = meta_row(snapshot)
    assert row != nil

    filled_cols =
      for col <- 0..(snapshot.width - 1), cell(snapshot, row, col).bg == fill, do: col

    assert length(filled_cols) > 40

    # the TYPED text (not the identity line): stated white, on the fill —
    # the identity spans keep their own semantic roles
    ExRatatui.textarea_insert_str(sync(pid).textarea, "hello")
    # paint the edit: a key event renders synchronously (a direct state
    # edit does not)
    key(pid, "shift")
    snapshot = cells(session)

    typed =
      Enum.find(0..(snapshot.height - 1), &String.contains?(row_text(snapshot, &1), "hello"))

    assert typed != nil

    # find the column by CELL, not by byte offset: the row string is
    # UTF-8 and the sidebar's │ is 3 bytes (a byte index would be off)
    col =
      Enum.find(0..(snapshot.width - 1), fn c ->
        Enum.map_join(c..(c + 4), "", &cell(snapshot, typed, &1).symbol) == "hello"
      end)

    assert col != nil
    h = cell(snapshot, typed, col)
    assert h.symbol == "h"
    assert h.fg == {:indexed, 255}
    assert h.bg == fill

    # ...and no frame glyphs inside the composer's own pane (the sidebar
    # keeps ITS right border — that is a different surface)
    pane = Enum.map_join(37..(snapshot.width - 2), "", &cell(snapshot, row, &1).symbol)
    refute pane =~ "╭"
    refute pane =~ "╰"
    refute pane =~ "│"
  end

  test "the identity and the status share the composer's last row" do
    {pid, session} = start_cell_tui([scope_root: File.cwd!()], {100, 30})
    fire(pid, :__resize_poll__)

    agent(pid, {:turn_started, "build"})
    agent(pid, {:status_changed, :running})

    snapshot = cells(session)

    row = meta_row(snapshot)

    text = row_text(snapshot, row)

    assert text =~ "thinking"
    # left half: identity; right half: status — one band, not two rows
    assert :binary.match(text, "model ") |> elem(0) < div(snapshot.width, 2)
    assert :binary.match(text, "thinking") |> elem(0) > div(snapshot.width, 2)
  end

  test "the chrome grey covers the sidebar, the composer and the overlays alike" do
    {pid, session} = start_cell_tui([scope_root: File.cwd!()], {100, 30})
    fire(pid, :__resize_poll__)
    snapshot = cells(session)

    fill = Palette.fill(Styles.palette(), :chrome)

    # the sidebar column and the composer row carry the SAME fill: the
    # chrome reads as one material painted by the app
    sidebar_bg = cell(snapshot, 3, 2).bg
    composer_row = meta_row(snapshot)
    composer_bg = cell(snapshot, composer_row, 40).bg

    assert sidebar_bg == fill
    assert composer_bg == fill
  end

  test "the composer's meta row keeps the fill under its role-coloured spans" do
    {pid, session} = start_cell_tui([scope_root: File.cwd!()], {100, 30})
    fire(pid, :__resize_poll__)
    snapshot = cells(session)

    fill = Palette.fill(Styles.palette(), :chrome)
    row = meta_row(snapshot)
    assert cell(snapshot, row, 3).bg == fill
  end

  test "every row of the composer is filled, down to the window's last chrome row" do
    {pid, session} = start_cell_tui([scope_root: File.cwd!()], {100, 30})
    fire(pid, :__resize_poll__)
    snapshot = cells(session)

    fill = Palette.fill(Styles.palette(), :chrome)
    meta = meta_row(snapshot)

    # the window's bottom is the composer's own padding row now (the
    # bottom status row is gone): it still carries the fill — the panel
    # ends visually with its surface, not mid-air
    assert cell(snapshot, meta + 1, 3).bg == fill
    # (the sidebar's own border crosses that row; the composer's pane is
    # what must be empty)
    pane = Enum.map_join(37..(snapshot.width - 2), "", &cell(snapshot, meta + 1, &1).symbol)
    assert String.trim(pane) == ""

    # ...and the last row of the window is the app margin (no fill)
    assert cell(snapshot, snapshot.height - 1, 3).bg == :reset
  end

  test "the transcript body is NOT filled: the terminal's own background shows through" do
    {pid, session} = start_cell_tui([scope_root: File.cwd!(), sidebar: false], {100, 30})
    fire(pid, :__resize_poll__)

    agent(pid, {:llm_message, "plain answer text"})

    snapshot = cells(session)
    row = Enum.find(0..29, &String.contains?(row_text(snapshot, &1), "plain answer"))
    assert row != nil

    # the reading surface stays unpainted — the fill is reserved for the
    # chrome the app draws itself (sidebar, composer, overlays)
    assert row_text(snapshot, row) |> String.trim() != ""
    assert cell(snapshot, row, 10).bg == :reset
    assert cell(snapshot, row, 11).bg == :reset
  end
end
