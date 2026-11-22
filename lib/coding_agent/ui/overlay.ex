# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.Overlay do
  @moduledoc """
  Where a dialog sits, and how wide it may be.

  Every overlay (the approval gate, the budget and doom prompts, the
  question wizard, the menu, the file picker, the command palette) shares
  three numbers, and they are the same three numbers for every one of
  them:

    * the **room**: the rows above the live band. An overlay may cover the
      transcript (the least costly surface) but never the input field or
      the band — the band is the running turn's status, and a dialog that
      hid it would hide the one row the owner asked to keep in sight.
    * the **width**: capped at the reading measure, so a wide terminal does
      not stretch a dialog edge to edge.
    * the **rect**: bottom edge on the room's last row, centred, at most as
      tall as the room.

  They are one function each, because they were once a constant per call
  site: `area.height - 4` was the cap here and `area.height - h - 3` the
  offset there, and a 26-row menu on a 30-row window came out with a
  negative `y` (measured live as `draw error: rect.y unexpected value`).
  The heights are MEASURED now, not assumed: a grown input pushes the band
  up and every overlay moves with it.

  Nothing here reads a TUI state struct — the caller passes the input
  height it already has (`UI.Composer.height_for/3`).
  """

  alias ExRatatui.Layout.Rect

  # The reading measure. Beyond ~100 characters the eye loses the
  # return-sweep (newspapers and books sit at 45-90), so the content
  # column is capped and the overlays are sized from the same number
  # instead of each picking its own width.
  @measure 100

  @doc "The reading measure (the widest useful content column)."
  @spec measure() :: pos_integer()
  def measure, do: @measure

  @doc """
  The rows an overlay may occupy: everything above the live band, minus
  the band's own row and the air rows around it.
  """
  @spec room(Rect.t(), non_neg_integer()) :: pos_integer()
  def room(%Rect{height: height}, input_h) do
    max(height - input_h - CodingAgent.UI.LiveBand.height() - 2, 1)
  end

  @doc """
  An overlay's rect: as tall as it asked for (clamped to the room), at
  most `measure + 2` wide (clamped to the window), centred, with its
  bottom edge on the room's last row.
  """
  @spec rect(Rect.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: Rect.t()
  def rect(%Rect{} = area, input_h, h, w) do
    room = room(area, input_h)
    h = min(h, room)

    %Rect{
      x: div(max(area.width - min(w, area.width), 0), 2),
      y: room - h,
      width: min(w, max(area.width, 1)),
      height: h
    }
  end

  @doc """
  The width a dialog or popup may claim: the reading measure plus the
  panel's own border cells, never wider than the window minus the frame's
  margins.
  """
  @spec width(Rect.t()) :: pos_integer()
  def width(%Rect{width: width}), do: min(@measure + 2, max(width - 4, 1))
end
