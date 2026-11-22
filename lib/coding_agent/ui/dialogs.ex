# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.Dialogs do
  @moduledoc """
  The blocking surfaces: the approval gate, the budget and doom prompts, and
  the question wizard.

  These are the four places where the app takes the keyboard away and asks
  the human a question. They are one module because they share the same
  frame (`Overlay.rect/4`, a double border in a role colour, a `Clear`
  beneath) and the same failure mode if they drift: a dialog that does not
  fit its room, or two dialogs painting at once.

  The module paints; it does not decide. Which surface is up, and what the
  keys mean, stays in `UI.Tui` — this module is handed the state of each
  prompt (`new/1`) and returns the widgets for whichever is set.

  ## Why the approval body is a padded string and not a widget

  Widget-level `bg` did not fill the rect headless, and the `Clear`
  variants killed the render cycle (measured). The body is therefore a
  joined string padded with per-row spaces to the panel's height; the
  background comes from the widget-level style.
  """

  alias CodingAgent.Core.ToolCall
  alias CodingAgent.UI.{Overlay, Styles, TranscriptView}
  alias ExRatatui.Widgets.{Clear, Markdown, Paragraph}

  @type t :: %__MODULE__{
          pending: [map()],
          deciding?: boolean(),
          budget: non_neg_integer() | nil,
          doom: String.t() | nil,
          question: map() | nil
        }

  defstruct pending: [], deciding?: false, budget: nil, doom: nil, question: nil

  @doc "Builds the dialog set from the prompts the TUI currently holds."
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  The widgets for whichever surface is up, bottom layer first. Empty when
  no surface is up, so the renderer can append the list unconditionally.
  """
  @spec widgets(t(), ExRatatui.Layout.Rect.t(), non_neg_integer()) :: [
          {ExRatatui.widget(), ExRatatui.Layout.Rect.t()}
        ]
  def widgets(%__MODULE__{} = dialogs, area, input_h) do
    budget_widgets(dialogs, area, input_h) ++
      doom_widgets(dialogs, area, input_h) ++
      question_widgets(dialogs, area, input_h) ++
      approval_widgets(dialogs, area, input_h)
  end

  # -- the approval gate (ADR 010) -------------------------------------------

  defp approval_widgets(%__MODULE__{pending: []}, _area, _input_h), do: []
  defp approval_widgets(%__MODULE__{deciding?: true}, _area, _input_h), do: []

  defp approval_widgets(%__MODULE__{pending: pending} = dialogs, area, input_h) do
    pending
    |> Enum.with_index()
    |> Enum.map(fn {call, i} ->
      {_id, name, args} = ToolCall.normalize(call)
      pretty = pretty_args(args)

      # Escalations carry the agent's stated reason (ADR 015): show it
      # first, so the human reads WHY before the raw arguments.
      reason =
        case escalation_reason(args) do
          nil -> ""
          r -> "why: #{r}\n\n"
        end

      text =
        "#{name}(#{pretty})\n\n" <>
          reason <>
          "y = approve   n = reject   e = edit (soon)"

      h =
        min(
          6 + length(String.split(pretty, "\n")) + length(String.split(reason, "\n")),
          div(area.height, 2)
        )

      panel(
        dialogs,
        area,
        input_h,
        padded(text, h),
        " APPROVAL #{i + 1}/#{length(pending)} ",
        Styles.role(:warning, :chrome),
        :Paragraph
      )
    end)
    |> List.flatten()
  end

  # -- the tool-round budget (ADR 025) ---------------------------------------

  defp budget_widgets(%__MODULE__{budget: nil}, _area, _input_h), do: []

  defp budget_widgets(%__MODULE__{budget: budget} = dialogs, area, input_h) do
    text =
      "The turn has used its #{budget}-round tool budget.\n\n" <>
        "y = continue (another #{budget} rounds)   n = stop (summarize)"

    panel(
      dialogs,
      area,
      input_h,
      padded(text, min(6, div(area.height, 2))),
      " TOOL BUDGET ",
      Styles.role(:warning, :chrome),
      :Paragraph
    )
  end

  # -- the doom loop (ADR 026) -----------------------------------------------

  defp doom_widgets(%__MODULE__{doom: nil}, _area, _input_h), do: []

  defp doom_widgets(%__MODULE__{doom: tool} = dialogs, area, input_h) do
    text =
      "Repeated call detected: #{tool} was called 3 times with identical\n" <>
        "arguments. This is usually a loop.\n\n" <>
        "y = continue (run it anyway)   n = reject (change approach)"

    panel(
      dialogs,
      area,
      input_h,
      padded(text, min(7, div(area.height, 2))),
      " DOOM LOOP ",
      Styles.role(:warning, :chrome),
      :Paragraph
    )
  end

  # -- the question wizard (ADR 027) -----------------------------------------

  defp question_widgets(%__MODULE__{question: nil}, _area, _input_h), do: []

  defp question_widgets(%__MODULE__{question: qp}, area, input_h) do
    question = Enum.at(qp.questions, qp.index)
    options = question["options"] || []

    body = question_markdown(question, qp, options)

    title =
      case question["header"] do
        hdr when is_binary(hdr) and hdr != "" -> hdr
        _ -> "QUESTION"
      end

    # The probe measures the boxless markdown at the rect's INNER width;
    # the panel's border adds the 2 rows back. Verified against the drawn
    # buffer at 100/62/40 cols: the bottom border lands on the rect's last
    # row, nothing clipped (the boxed widget wraps one column tighter than
    # the boxless probe on both sides, which the height's last-nonblank
    # metric absorbs).
    w = Overlay.width(area)
    h = min(TranscriptView.height({:reasoning, body}, w - 2, nil) + 2, area.height - 2)

    widget = %Markdown{
      content: body,
      style: Styles.surface(:chrome),
      block:
        Styles.panel(
          title: " #{title} ",
          surface: :chrome,
          border_style: Styles.role(:accent, :chrome),
          border_type: :double
        )
    }

    rect = Overlay.rect(area, input_h, h, w)
    [{%Clear{}, rect}, {widget, rect}]
  end

  # The wizard body in markdown. Terms are hard-wrapped single lines
  # (option rows must stay rows — a description never merges into the next
  # term's line), options separated by blank-QUOTE separators (see
  # options_deflist — a plain blank line paints with no gap); the "type your
  # own" row is an answer row like any other, so it gets the same
  # separator. tui-markdown renders the description on its own ": " line
  # (the definition-list look, verified against the painted buffer).
  @doc false
  def question_markdown(question, qp, options) do
    hint =
      if question["multiple"] || false do
        "  \n(select one or more)"
      else
        nil
      end

    controls =
      "enter = confirm   esc = skip" <>
        if(length(qp.questions) > 1,
          do: "   question #{qp.index + 1}/#{length(qp.questions)}",
          else: ""
        )

    answers =
      if options == [] do
        custom_entry(qp.custom)
      else
        options_deflist(options, qp.selected) <> "\n\n>\n\n" <> custom_entry(qp.custom)
      end

    [
      hard_breaks(String.trim(question["question"] || "")),
      hint,
      "",
      answers,
      "",
      controls
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # The options as a definition list: the bold term carries the digit key
  # (literal inside **…**), the description hangs below as ": …". Blocks are
  # separated by an EMPTY BLOCKQUOTE (`>`): the def-list parser eats blank
  # lines between blocks (measured — "\n\n" paints with no gap), so a plain
  # paragraph separator shows nothing. A blockquote opens a new top-level
  # block, which ratatui's spacer paints as a blank row even when empty —
  # and a description or label containing "> x" merges into the def-list
  # paragraph (lazy continuation) instead of breaking it.
  #
  # Labels, descriptions and the custom buffer are MODEL/USER text embedded
  # in that structure, so each is reduced to ONE line first: a newline
  # inside a label leaves the bold term unclosed and a blank line in a
  # description escapes the def-list (measured — "evil\n>\n\n## x" painted
  # as a heading). Flattening whitespace keeps the option rows rows, which
  # is the structure's contract.
  @doc false
  def options_deflist(options, selected) do
    options
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n>\n\n", fn {o, i} ->
      mark = if (i - 1) in selected, do: "▸ ", else: ""
      term = "#{mark}**#{i}) #{single_line(o["label"])}**"

      case single_line(o["description"]) do
        "" -> term
        desc -> term <> "\n: " <> desc
      end
    end)
  end

  # The always-present "type your own" row; while a custom answer is being
  # typed it carries the buffer and the cursor.
  defp custom_entry(nil), do: "**0) type your own answer…**"
  defp custom_entry(buf), do: "▸ **0) #{single_line(buf)}▏**"

  # One line, always: whitespace runs (newlines included) collapse to a
  # single space, so embedded text cannot open a markdown block or close its
  # own emphasis.
  @doc false
  def single_line(nil), do: ""
  def single_line(text) when is_binary(text), do: text |> String.split() |> Enum.join(" ")
  def single_line(_), do: ""

  # A paragraph's own newlines must not open new blocks: make them hard
  # breaks so the question's line structure survives the markdown parse.
  defp hard_breaks(text), do: String.replace(text, "\n", "  \n")

  # -- the agent's stated reason (ADR 015) -----------------------------------

  # Shown for any call that STATES a reason — `git` carries the same
  # `network` escalation `shell` does, so this keys off the arguments, not
  # the tool name (a file tool can state a `reason` too; then it is shown,
  # and the gate ignores it, since that tool declares no escalation to
  # attach it to).
  @doc false
  def escalation_reason(args) do
    case Map.get(args, "reason") || Map.get(args, :reason) do
      r when is_binary(r) and r != "" -> r
      _ -> nil
    end
  end

  # `reason` is rendered separately as "why:" — omit it from the raw
  # argument list so the dialog does not say the same thing twice. The
  # escalation booleans stay visible: they are the grant being approved, and
  # `git` now carries one too (`network`).
  @hidden_args ~w(reason)

  @doc false
  def pretty_args(args) do
    args
    |> Enum.reject(fn {k, _} -> to_string(k) in @hidden_args end)
    |> Enum.map(fn {k, v} ->
      v_str = if is_binary(v) and String.contains?(v, "\n"), do: inspect(v), else: to_string(v)
      "#{k}: #{String.slice(v_str, 0, 160)}"
    end)
    |> Enum.join("\n")
  end

  # -- the shared frame ------------------------------------------------------

  # One dialog: the rect from `Overlay`, a double border in the caller's
  # role, and the body on the chrome surface.
  defp panel(_dialogs, area, input_h, body, title, border_style, _kind) do
    widget = %Paragraph{
      text: body,
      style: Styles.surface(:chrome),
      block:
        Styles.panel(
          title: title,
          surface: :chrome,
          border_style: border_style,
          border_type: :double
        )
    }

    w = Overlay.width(area)
    rect = Overlay.rect(area, input_h, dialog_height(body), w)
    [{%Clear{}, rect}, {widget, rect}]
  end

  # The panel's height from its own body: one border row top and bottom,
  # and the body's lines.
  defp dialog_height(body), do: length(String.split(body, "\n")) + 2

  # Pad the body to `h` rows with per-row spaces, so the widget's style
  # covers the whole panel (a widget-level bg alone did not fill headless).
  defp padded(text, h) do
    text
    |> String.split("\n")
    |> Enum.concat(List.duplicate(" ", max(h - 2 - length(String.split(text, "\n")), 0)))
    |> Enum.join("\n")
  end
end
