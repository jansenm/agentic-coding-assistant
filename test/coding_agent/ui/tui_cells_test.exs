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

  The live band (the status row ABOVE the field) is the one place the
  transcript's UNPAINTED surface and the chrome fill meet inside a single
  column: the band keeps the base background while the composer below it
  carries the grey, so a colour regression there reads as "the band turned
  into a third slab of chrome".
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
    # the identity spans keep their own semantic roles. TYPE it (key
    # events render synchronously; a direct state edit does not paint)
    for ch <- ["h", "e", "l", "l", "o"], do: key(pid, ch)
    snapshot = cells(session)

    typed =
      Enum.find(0..(snapshot.height - 1), &String.contains?(row_text(snapshot, &1), "hello"))

    assert typed != nil

    # find the column by CELL, not by byte offset: the row string is
    # UTF-8 and a 3-byte glyph earlier in the row would shift a byte index
    col =
      Enum.find(0..(snapshot.width - 1), fn c ->
        Enum.map_join(c..(c + 4), "", &cell(snapshot, typed, &1).symbol) == "hello"
      end)

    assert col != nil
    h = cell(snapshot, typed, col)
    assert h.symbol == "h"
    assert h.fg == {:indexed, 255}
    assert h.bg == fill

    # ...and no frame glyphs anywhere in the composer's own pane (the
    # sidebar is a different surface and has no rule either)
    pane = Enum.map_join(37..(snapshot.width - 2), "", &cell(snapshot, row, &1).symbol)
    refute pane =~ "╭"
    refute pane =~ "╰"
    refute pane =~ "│"
  end

  test "the band carries the status, the composer's row carries the setup" do
    {pid, session} = start_cell_tui([scope_root: File.cwd!()], {100, 30})
    fire(pid, :__resize_poll__)

    agent(pid, {:turn_started, "build"})
    agent(pid, {:status_changed, :running})

    snapshot = cells(session)

    # the status words are unique in the frame: the composer's row below
    # the field paints none (it is SETUP), so this row IS the band
    band =
      Enum.find(0..(snapshot.height - 1), &String.contains?(row_text(snapshot, &1), "thinking"))

    assert band != nil

    text = row_text(snapshot, band)
    assert text =~ "agent build"
    assert text =~ "model "

    # the band sits ABOVE the composer's meta row
    assert band < meta_row(snapshot)

    # ...and the band's row is NOT the composer's surface: it keeps the
    # transcript's unpainted background (the owner's "distinguish it by
    # background, use the black of the output section"), including the
    # padding cells to the left of the row's text
    assert cell(snapshot, band, 37).bg == :reset
    assert cell(snapshot, band, 38).bg == :reset
    assert cell(snapshot, band - 1, 40).bg == :reset
    assert cell(snapshot, band + 1, 40).bg == :reset
  end

  test "the band has one cell of padding on all four sides" do
    {pid, session} = start_cell_tui([scope_root: File.cwd!()], {100, 30})
    fire(pid, :__resize_poll__)
    snapshot = cells(session)

    band = Enum.find(0..(snapshot.height - 1), &String.contains?(row_text(snapshot, &1), "idle"))
    assert band != nil

    # the band rect starts where the sidebar's column ends; its first
    # cell is the LEFT padding, and the status text begins one cell later
    assert cell(snapshot, band, 37).symbol == " "
    assert cell(snapshot, band, 38).symbol != " "
    assert String.starts_with?(row_text(snapshot, band) |> String.slice(37..-1//1), " ○ idle")
    # the right padding: the row's last cell inside the mid area is blank
    assert cell(snapshot, band, snapshot.width - 2).symbol == " "

    # vertically: the band's own rect is three rows (padding, row,
    # padding) and the row BELOW it is still base — the chrome field only
    # starts after the air row (measure = paint: two blank rows between
    # the status text and the input field)
    assert cell(snapshot, band + 1, 40).bg == :reset
    assert cell(snapshot, band + 2, 40).bg == :reset
    assert cell(snapshot, band + 3, 40).bg == Palette.fill(Styles.palette(), :chrome)
  end

  test "the band is painted in the SAME frame rows the layout reserves for it" do
    # measure = paint: the transcript pane height the renderer paints at
    # IS the pane the hit-test, the clamp and the diagnostics measure.
    # The band is 3 rows (padding, row, padding) + 2 air rows.
    {pid, session} = start_cell_tui([scope_root: File.cwd!(), sidebar: false], {100, 30})
    fire(pid, :__resize_poll__)

    st = sync(pid)

    composer_h =
      CodingAgent.UI.Composer.height(CodingAgent.UI.Composer.new(textarea: st.textarea))

    # 30 rows - margin(2) - spacing(2) - band(3) - composer(5: an EMPTY
    # field measures 5, one row under `min_height/0`, which is the floor
    # before a textarea exists)
    assert composer_h == 5
    pane = CodingAgent.UI.Tui.pane_rect(st)
    assert pane.height == 30 - 2 - 2 - 3 - composer_h

    # the band's status row is one row past the transcript + the air row
    # (its own first row is the top padding). `pane.y` is where the pane
    # STARTS, which is what the hit-test needs (it used to assume row 1).
    snapshot = cells(session)
    band = Enum.find(0..29, &String.contains?(row_text(snapshot, &1), "idle"))
    assert band == pane.y + pane.height + 2
    assert pane.y == 1
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

  # The sidebar's identity block (the redesign): the scope heads the panel
  # as a BOLD body line (not a Block title floating one cell in from the
  # fill), and the model spec is split into its two halves so neither is
  # clipped. Both facts are colour/column facts, so they are asserted on
  # the cell buffer.
  test "the sidebar heads with a bold scope and splits model from provider" do
    {pid, session} = start_cell_tui([scope_root: File.cwd!()], {100, 30})
    fire(pid, :__resize_poll__)
    snapshot = cells(session)

    scope = Path.basename(File.cwd!())
    heading_row = Enum.find(0..29, &String.contains?(row_text(snapshot, &1), scope))
    assert heading_row != nil

    # the heading carries the emphasis role ON the sidebar fill: white and
    # bold (the composer's own identity line stays muted, so this is the
    # panel's heading and not a stray span)
    emphasis = Palette.resolve(Styles.palette(), :emphasis, :sidebar)
    lead = String.length(row_text(snapshot, heading_row) |> String.split(scope) |> List.first())

    assert cell(snapshot, heading_row, lead).symbol == String.first(scope)
    assert cell(snapshot, heading_row, lead).fg == emphasis.fg
    assert :bold in cell(snapshot, heading_row, lead).modifiers
    assert cell(snapshot, heading_row, lead).bg == Palette.fill(Styles.palette(), :sidebar)

    # the model spec is split: the id and its provider each own a row, so
    # neither half is clipped (the single badge cut "…deepseek-v4.1-fl|")
    [provider, id] = (sync(pid).model || ":") |> String.split(":", parts: 2)

    model_row =
      Enum.find(0..29, fn r ->
        t = row_text(snapshot, r)
        String.contains?(t, "model:") and String.contains?(t, id)
      end)

    provider_row = Enum.find(0..29, &String.contains?(row_text(snapshot, &1), "provider:"))

    assert model_row != nil
    assert provider_row != nil
    assert model_row < provider_row
    assert row_text(snapshot, provider_row) =~ "provider: #{provider}"

    # the heading and the identity labels share ONE column: the heading is
    # panel content, flush with the rows below it (a Block title sat one
    # cell further right, which is the look O4 removed)
    assert lead == grapheme_col(row_text(snapshot, model_row), "model:")
  end

  # The column a substring starts at, in graphemes (a row string is UTF-8
  # and the tree glyph "▸" is 3 bytes — a byte offset would be off).
  defp grapheme_col(row, needle) do
    {at, _len} = :binary.match(row, needle)
    row |> binary_part(0, at) |> String.graphemes() |> length()
  end
end
