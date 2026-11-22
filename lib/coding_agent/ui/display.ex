# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.Display do
  @moduledoc """
  What a session's text looks like on screen: the stream buffer, the entries
  the painter draws, the two text shapes (a reasoning trace, a markdown
  answer), and the caps that keep a block from eating the screen.

  Three consumers read the same string, and they must not disagree: the
  **measure** (`UI.TranscriptView.height/3` renders the widget to count
  rows), the **paint** (the widget `UI.Tui` builds), and the
  **persistence** (what a finished block becomes in the transcript). Every
  disagreement has landed the same way — the entry reserves rows the widget
  never paints, or paints rows the entry clipped, and the error compounds
  while a block streams. The "scroll up three screens of blanks" bug is the
  canonical one: a trailing `"\\n"` counted as a row here and painted no row
  there.

  So a shape is applied ONCE, here, at entry-normalization, and the render
  path trusts it. Nothing in this module reads a TUI state struct or a
  clock: `UI.Tui` resolves the values (`transcript`, `stream`,
  `turn_agents`, `active_agent`) and hands them over, exactly as it does for
  the sidebar and the stats popup.

  ## The caps are display policy, not session truth

  A 200-line reasoning trace and a 4000-line test run are both real, and the
  session keeps both in full. What the transcript shows is a bounded view —
  head and tail for tool output, the first `@thinking_cap` lines for a
  reasoning trace — because a block that eats the screen is a block the
  human scrolls past, and the escape hatch (collapse, reopen, `/export`) is
  one keystroke away.
  """

  @typedoc """
  A transcript entry in display shape: the text plus, for the roles a turn
  can be attributed to, the agent that spoke.
  """
  @type entry ::
          {:user, String.t(), String.t() | nil}
          | {:assistant, String.t(), String.t() | nil}
          | {:reasoning, String.t()}
          | {:info, String.t(), String.t() | nil}
          | {:summary, String.t()}
          | {:tool, String.t(), String.t(), String.t()}

  @typedoc "One buffered stream block: the kind of delta and the text so far."
  @type block :: {:assistant | :reasoning, String.t()}

  # How many rows of a tool result the expanded block shows: head + tail
  # with an elision note in the middle.
  @tool_cap 30

  # How many rows of a reasoning trace survive into the transcript. The live
  # stream shows everything while it arrives; the committed entry is the
  # distilled one.
  @thinking_cap 12

  # -- the stream buffer -----------------------------------------------------

  @doc """
  Appends a streamed delta to the IN-ORDER buffer. A delta of the SAME kind
  extends the last block; a kind SWITCH opens a new block, so reasoning and
  answer text keep their interleaved arrival order (a statement made between
  thoughts stays there).

  The cursor `"▌"` is not stored here — `streaming_entries/1` appends it to
  the last assistant block at render time, so the buffer stays the thing a
  turn can persist unchanged.
  """
  @spec append_stream([block()], :assistant | :reasoning, String.t()) :: [block()]
  def append_stream([], kind, delta), do: [{kind, normalize_block(kind, delta)}]

  def append_stream(stream, kind, delta) do
    case List.last(stream) do
      {^kind, prev} ->
        List.replace_at(stream, -1, {kind, normalize_block(kind, prev <> delta)})

      _other ->
        stream ++ [{kind, normalize_block(kind, delta)}]
    end
  end

  # Both kinds are markdown now, so both are kept verbatim (only CRs
  # stripped): blank lines are paragraph breaks and CommonMark collapses
  # runs of them to one, so the GLM-split-delta runaway ("l1\n" + "\n"
  # across deltas) cannot grow the box the way it did under Paragraph.
  # The RAW buffer keeps trailing newlines; only the DISPLAY shape
  # (`render_reasoning/1`) trims them, because the window math must never
  # see a phantom trailing row.
  defp normalize_block(:assistant, text), do: text
  defp normalize_block(:reasoning, text), do: String.replace(text, "\r", "")

  @doc """
  The in-flight stream as display entries, in order; the last assistant
  block carries the cursor. Reasoning blocks are trimmed so every consumer
  (measure, viewport, widget) sees the same string the widget paints — the
  raw buffer keeps its trailing `"\\n"` and the window math overcounted the
  phantom row per frame (found live: "scroll up three screens of blanks").
  """
  @spec streaming_entries([block()]) :: [entry()]
  def streaming_entries([]), do: []

  def streaming_entries(stream) do
    last = length(stream) - 1

    stream
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:reasoning, text}, _i} ->
        case render_reasoning(text) do
          "" -> []
          t -> [{:reasoning, t}]
        end

      {{:assistant, text}, ^last} ->
        [{:assistant, text <> "▌"}]

      {{:assistant, text}, _i} ->
        [{:assistant, text}]
    end)
  end

  # -- text shapes ----------------------------------------------------------

  @doc """
  The display shape of the thinking buffer, shared by measure, paint and
  persistence so all three see the same string. Two independent jobs, kept
  separate because they have different reasons to exist:

  1. `harden_line_breaks/1` — VISUAL line structure, load-bearing.
     CommonMark treats a lone `"\\n"` as a SOFT break that joins lines
     ("line one line two"), but a reasoning trace is line-structured, so
     each non-blank line that has a following line gets a HARD break (two
     trailing spaces). Markdown still parses headings/bold/code; the lines
     just stay lines. It also skips fenced code so literal text is not
     corrupted.

  2. The trailing `"\\n"` trim — a BUFFER/WINDOW consistency invariant,
     not a markdown concern. A trailing newline is a phantom empty row in
     the window math (the "scroll up three screens of blanks" bug), so the
     displayed string must never end in `"\\n"`; the consumers that append
     `"\\n"` (window math, persistence) rely on that.

  Runs of blank lines need no handling: CommonMark collapses them to a
  single paragraph break on its own. The old Paragraph-era "runaway blanks"
  squeeze is obsolete.
  """
  @spec render_reasoning(String.t()) :: String.t()
  def render_reasoning(text) do
    text
    |> String.replace_trailing("\n", "")
    |> harden_line_breaks()
  end

  # Two trailing spaces = CommonMark hard break, applied to every
  # non-blank line that has a following line. Lines inside a ``` fence
  # and the fence markers themselves are skipped: code blocks preserve
  # their own newlines and injected spaces corrupt the literal text.
  # Idempotent (a line already ending in "  " is left alone) because it
  # still runs on restored entries (the resume boundary hardens through
  # `persist_reasoning/1` too); the live path hardens once and never again
  # per frame.
  defp harden_line_breaks(text) do
    lines = String.split(text, "\n")
    last = length(lines) - 1

    {lines, _} =
      lines
      |> Enum.with_index()
      |> Enum.map_reduce(false, fn {line, i}, in_fence ->
        fence? = String.starts_with?(String.trim_leading(line), "```")

        line =
          if in_fence or fence? or i == last or String.trim(line) == "" or
               String.ends_with?(line, "  ") do
            line
          else
            line <> "  "
          end

        {line, if(fence?, do: not in_fence, else: in_fence)}
      end)

    Enum.join(lines, "\n")
  end

  @doc """
  The brevity cap for tool output shown expanded: keep head + tail with an
  elision note in the middle.

  Tails matter for test output; the full content is never far — collapse
  plus reopen is the escape hatch, and the session keeps the truth.
  """
  @spec cap_lines(String.t()) :: String.t()
  def cap_lines(text) do
    # trim trailing blanks first: a read_file with 20+ trailing empty
    # lines would otherwise make the CAP keep only blanks as its tail
    # ('large blocks end in a wall of empty lines', found live)
    lines =
      text
      |> String.split("\n")
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()

    # decide AND build from the TRIMMED lines: returning the raw text
    # here un-trimmed 20 trailing blanks right back in (found live:
    # the trim made the content look short enough to skip the cap)
    if length(lines) <= @tool_cap do
      Enum.join(lines, "\n")
    else
      head = Enum.take(lines, 10)
      tail = Enum.take(lines, -10)
      kept = length(lines) - 20

      Enum.join(head, "\n") <>
        "\n… (#{kept} lines elided — full output lives in the core session) …\n" <>
        Enum.join(tail, "\n")
    end
  end

  # -- what a finished block becomes ----------------------------------------

  @doc """
  Persists the in-flight stream as transcript entries, in arrival order.

  `final_text` is the authoritative answer from the session; when no
  assistant delta streamed at all (a non-streamed or resumed turn) it
  becomes the single assistant entry, so an answer is never dropped.
  """
  @spec persist_stream([block()], String.t() | nil) :: [entry()]
  def persist_stream([], nil), do: []

  def persist_stream([], final_text), do: [{:assistant, breathe(final_text)}]

  def persist_stream(stream, final_text) do
    stream
    |> Enum.flat_map(fn
      {:reasoning, text} ->
        case persist_reasoning(text) do
          nil -> []
          entry -> [entry]
        end

      {:assistant, text} ->
        if String.trim(text) == "", do: [], else: [{:assistant, breathe(text)}]
    end)
    |> ensure_answer(final_text)
  end

  # If deltas streamed only reasoning (no assistant text), fall back to
  # the session's final text so the answer is never dropped.
  defp ensure_answer(entries, nil), do: entries

  defp ensure_answer(entries, final_text) do
    if Enum.any?(entries, &match?({:assistant, _}, &1)) do
      entries
    else
      entries ++ [{:assistant, breathe(final_text)}]
    end
  end

  @doc """
  A finished thinking trace as a transcript entry, or `nil` when there is
  nothing to show (blank, or nothing left after the cap).

  This is the ONE place reasoning text is trimmed and capped for display, so
  the live path and the resume path cannot drift (review N10).
  """
  @spec persist_reasoning(String.t()) :: {:reasoning, String.t()} | nil
  def persist_reasoning(reasoning) do
    case cap_reasoning(render_reasoning(reasoning)) do
      nil -> nil
      text -> {:reasoning, text}
    end
  end

  # Blank -> nil (nothing to show), otherwise the first @thinking_cap lines.
  defp cap_reasoning(text) do
    case String.trim(text) do
      "" ->
        nil

      trimmed ->
        lines = String.split(trimmed, "\n")

        if length(lines) > @thinking_cap,
          do: Enum.take(lines, @thinking_cap) |> Enum.join("\n"),
          else: trimmed
    end
  end

  # -- the display lists ----------------------------------------------------

  @doc """
  The full display list for the parent transcript, each entry carrying the
  agent of the turn it belongs to.

  `turn_agents` attributes the i-th USER turn (seeded on mount from the
  session, extended at send time with the next agent); every entry up to the
  next user belongs to that turn. Compaction and other info lines are
  attributed to the agent that triggered them; reasoning stays unattributed
  by design.

  Streaming entries (not yet in the transcript) carry the CURRENT turn's
  agent: the last recorded turn agent when there is one, else
  `active_agent` — the same fallback the transcript path uses, so a streamed
  answer and its persisted form agree.
  """
  @spec entries([entry()], [block()], [String.t() | nil] | nil, String.t() | nil) :: [entry()]
  def entries(transcript, stream, turn_agents, active_agent) do
    agents = turn_agents || []

    {rows, _turn, _last} =
      Enum.reduce(transcript || [], {[], 0, nil}, fn entry, {acc, turn, last} ->
        case entry do
          {:user, t} ->
            agent = Enum.at(agents, turn)
            {[{:user, t, agent} | acc], turn + 1, agent}

          {:assistant, t} ->
            # attribute to the CURRENT turn's agent; when the turn_agents
            # seed hasn't been extended locally yet (a fresh session, or an
            # agent-less one where the local send never recorded a name),
            # fall back to the live turn's agent so the assistant box footer
            # shows the real agent, not the neutral "agent" label.
            agent = last || active_agent
            {[{:assistant, t, agent} | acc], turn, last}

          {:info, t} when is_binary(t) ->
            agent = last || active_agent
            {[{:info, t, agent} | acc], turn, last}

          {kind, _} when kind in [:reasoning, :tool] ->
            # already in display shape: live reasoning was hardened by
            # persist_reasoning/1 before it entered the transcript, resumed
            # reasoning by the resume boundary — so this hot path must NOT
            # re-run render_reasoning/1.
            {[entry | acc], turn, last}

          other ->
            {[other | acc], turn, last}
        end
      end)

    # prepend+reverse: the reduce accumulated in reverse, one O(n) pass.
    # (`acc ++ [x]` here made every frame O(n^2) — the second half of the
    # long-session lag.)
    rows = Enum.reverse(rows)

    # The live (streaming) entries carry the CURRENT turn's agent: the last
    # recorded turn agent when there is one, else the active_agent (from
    # {:turn_started, ...}) — the same fallback the transcript path uses, so
    # a streamed answer and its persisted form agree.
    live_agent = List.last(agents) || active_agent

    streaming =
      stream
      |> streaming_entries()
      |> Enum.map(fn
        {:assistant, t} -> {:assistant, t, live_agent}
        other -> other
      end)

    rows ++ streaming
  end

  @doc """
  A child tab's display list: its own committed transcript plus its live
  stream, with every assistant and info entry attributed to the child's own
  agent.

  The shapes are the parent's, so the tab reuses the parent render path
  instead of forking a second one.
  """
  @spec child_entries(map()) :: [entry()]
  def child_entries(child) do
    agent = Map.get(child, :agent)

    committed =
      Enum.map(Map.get(child, :transcript, []), fn
        {:assistant, t} -> {:assistant, t, agent}
        {:info, t} -> {:info, t, agent}
        other -> other
      end)

    streaming =
      child
      |> Map.get(:stream, [])
      |> streaming_entries()
      |> Enum.map(fn
        {:assistant, t} -> {:assistant, t, agent}
        other -> other
      end)

    committed ++ streaming
  end

  # -- markdown breathing ---------------------------------------------------

  # Visual breathing for markdown answers: ensure ONE blank line after
  # every heading (and one before, unless the heading opens the text). The
  # Markdown widget's own spacing is baked in and tight; this transform is
  # applied once at entry-normalization so measure and render see the same
  # string (heights never drift from it).
  defp breathe(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, _} ->
      heading? = String.match?(line, ~r/^\x23{1,6}\s/)

      acc =
        acc
        |> maybe_blank_before(heading?)
        |> List.insert_at(-1, line)
        |> maybe_blank_after(heading?)

      {acc, heading?}
    end)
    |> elem(0)
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  defp breathe(other), do: other

  defp maybe_blank_before(acc, true = _heading?) do
    case Enum.reverse(acc) do
      ["" | _] -> acc
      [] -> acc
      _ -> acc ++ [""]
    end
  end

  defp maybe_blank_before(acc, _), do: acc

  defp maybe_blank_after(acc, true = _heading?) do
    acc ++ [""]
  end

  defp maybe_blank_after(acc, _), do: acc
end
