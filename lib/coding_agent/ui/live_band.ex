# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.LiveBand do
  @moduledoc """
  The live band: the row above the composer that says what the RUNNING
  turn is doing — *which* agent and model are executing it, and whether
  it is thinking, running a tool, or waiting for an answer.

  Why a second status surface (owner decision, 2026-09-23): the composer's
  meta row below the field is SETUP — the agent and model the *next* input
  will use, which Tab and the model menu change. The status of the turn in
  flight is a different question, and the two answers can differ: Tab
  switches the next agent while the running turn keeps its own, and a
  model switch does not touch a turn already in flight. One row cannot
  answer both without lying about one of them.

  The band sits directly above the input field, on the transcript's own
  surface (`:base`, the terminal background), so it reads as part of the
  reading area rather than as another chrome slab. One cell of padding on
  all four sides keeps the text off its edge.

  ## The row

      agent build · model glm · ⠋ running mix · 38s
      ○ idle

  The status is ALWAYS here (owner decision: it belongs above the field,
  and the row is permanent so the layout never moves). It is composed by
  `Styles.status_line/6` — the ONE status vocabulary, so the wording, the
  glyphs, the spinner frames and the colour roles cannot fork from the
  status line the composer used to render.

  The identity prefix appears only while a turn is IN FLIGHT: that is the
  case where "what is running" can differ from "what the next input will
  use" (Tab switches the next agent; a running turn keeps its own). Idle,
  the composer's setup row below the field already names the agent and
  model, so repeating them here would be the same fact twice.
  """

  alias CodingAgent.UI.Styles
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text
  alias ExRatatui.Widgets.Paragraph

  # one cell of inset on all four sides, like the composer's padding ring
  @padding 1

  @type t :: %__MODULE__{
          agent: String.t() | nil,
          model: String.t() | nil,
          status: atom(),
          provider_down?: boolean(),
          spin: non_neg_integer() | nil,
          elapsed_s: non_neg_integer() | nil,
          label: String.t() | nil
        }

  defstruct agent: nil,
            model: nil,
            status: :idle,
            provider_down?: false,
            spin: nil,
            elapsed_s: nil,
            label: nil

  @doc "Builds a band from already-resolved values (see the moduledoc)."
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc "The band's height: one padding row, the status row, one padding row."
  @spec height() :: pos_integer()
  def height, do: @padding + 1 + @padding

  @doc """
  Places the band into `rect` and returns `{widget, rect}` tuples for
  `ExRatatui.draw/2`: the surface fill first (it must cover the whole
  rect — a widget-level background paints only the rows the widget
  writes), then the status paragraph inside the padding.
  """
  @spec placements(t(), Rect.t()) :: [{ExRatatui.widget(), Rect.t()}]
  def placements(%__MODULE__{} = band, %Rect{} = rect) do
    [
      {fill(), rect},
      {status_widget(band), inset(rect)}
    ]
  end

  # The band's surface: the transcript's own (unpainted) background, so
  # the band belongs to the reading area instead of being a third slab of
  # chrome under the transcript.
  defp fill, do: %Paragraph{text: "", block: Styles.panel(borders: [], surface: :base)}

  defp inset(rect) do
    %Rect{
      x: rect.x + @padding,
      y: rect.y + @padding,
      width: max(rect.width - 2 * @padding, 1),
      height: 1
    }
  end

  # The row's spans. Time and the "is the turn busy?" question are
  # answered by the caller (the TUI owns the clock, as for the composer);
  # this module only chooses the words and the roles.
  defp status_widget(band) do
    %Paragraph{
      text: Text.Line.new(row(band)),
      style: Styles.surface_bg(:base)
    }
  end

  # `agent build · model glm · ⠋ running mix · 38s`: identity, then the
  # status group, joined by the same separator. No identity at all (a
  # fresh session, nothing resolved yet) leaves the status alone on the
  # row, and the band is never empty — the row is always there.
  defp row(band) do
    case identity_parts(band) do
      [] -> status_spans(band)
      parts -> join(parts) ++ [separator() | status_spans(band)]
    end
  end

  # `agent build` / `model glm` — the identity of what is RUNNING, and
  # ONLY while a turn is in flight: idle, the composer's setup row below
  # the field already names the same agent and model, and a copy two rows
  # apart is not information. Each part is optional (`Styles.badge/3`
  # renders a bare label for a missing value).
  defp identity_parts(%{status: status} = band) do
    if Styles.busy?(status) do
      [
        band.agent && Styles.badge(:agent, band.agent),
        band.model && Styles.badge(:model, band.model)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn %Text.Line{spans: spans} -> spans end)
    else
      []
    end
  end

  # The status: the ONE vocabulary (`Styles.status_line/6`) — glyph,
  # spinner frame, colour roles and the elapsed formatting cannot fork
  # from the composer's own status line, because there is only one
  # composer of them. Its leading space is gone (the band's padding is
  # the inset), so the separator lands cleanly.
  defp status_spans(band) do
    step = if Styles.busy?(band.status), do: band.spin, else: nil

    %Text.Line{spans: spans} =
      Styles.status_line(band.status, band.provider_down?, step, band.elapsed_s, band.label)

    spans
  end

  defp separator, do: Text.Span.new(" · ", style: Styles.role(:muted))

  # every identity part on one line, joined by the same separator
  defp join(parts) do
    parts
    |> Enum.intersperse([separator()])
    |> List.flatten()
  end
end
