defmodule CodingAgent.UI.TranscriptView do
  @moduledoc """
  Pure transcript-window logic (5a render foundation, scroll from the
  user's "screen doesn't scroll" report): the pane shows the last
  `height` lines when `offset` is 0 (auto-follow), else a window ending
  `offset` lines above the bottom (scrolled back), clamped.

  Pure and unit-tested; UI.Tui renders the result.
  """

  @doc "Returns the visible lines for a pane of the given height."
  @spec window([String.t()], pos_integer(), non_neg_integer()) :: [String.t()]
  def window(lines, height, offset \\ 0)

  def window([], _height, _offset), do: []

  def window(lines, height, offset) when height >= 1 do
    total = length(lines)
    offset = min(offset, max(total - height, 0))
    from = max(total - height - offset, 0)
    Enum.slice(lines, from, height)
  end
end
