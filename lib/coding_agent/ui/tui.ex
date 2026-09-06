defmodule CodingAgent.UI.Tui do
  @moduledoc """
  The phase-5 terminal UI driver (5a render foundation + 5b interaction).

  Layout: transcript pane (scrollable) / input area / status line.
  Input is an ExRatatui Textarea — enter inserts a newline (ADR 011
  composition-first default); alt-enter sends the buffer to the agent.
  The ADR 011 keymap is the action table; UI.Bridge translates
  terminal events; UI.Keymap resolves actions.

  Approval flow (ADR 010): when the gate interrupts, the pending calls
  render as a dialog; y approves, n rejects, e edits — per-key editing
  of single-line values in the dialog (multiline values shown
  read-only; the CLI limitation does not recur: paste is a terminal
  event here, and args render pretty-printed).
  """

  use ExRatatui.App

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.Supervisor
  alias CodingAgent.Core.Session.Store
  alias CodingAgent.UI.{Bridge, Keymap, TranscriptView}
  alias ExRatatui.Event
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text
  alias ExRatatui.Widgets.{Block, Markdown, Paragraph, Textarea}

  @input_height 4
  @tool_cap 30

  # rows the transcript pane loses to chrome: app margin top+bottom (2)
  # + spacing above/below it (2) + input area + status line. Kept in
  # one place so the manual dimension math (mount/poller/resize/clamp)
  # stays honest against the real Layout.split in render/2.
  @layout_overhead 2 + 2 + @input_height + 1

  # columns the transcript loses: app margin left+right (2) + the
  # 1-cell inner inset the renderer uses (pane.x + 1 and width - 2)
  @width_overhead 4

  # reading measure (typography): the eye loses the return-sweep past
  # ~100 characters (newspapers/books: 45-90). On wider panes the
  # content column is capped and centered instead of stretching.
  @measure 100

  @impl true
  def mount(opts) do
    id = Keyword.get(opts, :session_id) || "tui-#{System.unique_integer([:positive])}"
    prompt = Keyword.get(opts, :initial_prompt)

    with {:ok, _pid, restored} <- start_session(id, opts) do
      # real terminal dimensions: captured at mount, kept fresh by a
      # resize poller (the local transport never dispatches Resize
      # events — nothing sends them, found live). In test_mode the
      # terminal_size() NIF can't see the virtual terminal (it reads
      # the HOST tty) — seed from the declared test size instead, or
      # the clamp math diverges from the renderer (found via the
      # straddle probes: clamp said 15 rows, renderer drew 31).
      initial_size =
        case Keyword.get(opts, :test_mode) do
          {w, h} when is_integer(w) and is_integer(h) ->
            {w, h}

          _ ->
            case ExRatatui.terminal_size() do
              {w, h} when is_integer(w) and is_integer(h) -> {w, h}
              _ -> {80, 24}
            end
        end

      Process.send_after(self(), :__resize_poll__, 500)
      # the ACTUAL session id (a resumed session keeps its persisted id)
      effective_id = (restored && restored.id) || id

      Session.subscribe(effective_id)

      # attach to the CURRENT state, not a stale idle assumption: the
      # session may already be running/interrupted (e.g. attached after
      # the gate paused, or resumed from disk)
      {status, pending} =
        case Session.state(effective_id) do
          {:ok, st} -> {st.status, st.pending_tool_calls}
          _ -> {:idle, []}
        end

      # resumed sessions render their history: the persisted context
      # becomes transcript lines (system prompts stay hidden)
      history = (restored && restored_history(restored)) || []

      {tw, th} = initial_size

      initial = %{
        session_id: effective_id,
        last_pane_width: max(tw - @width_overhead, 10),
        last_pane_height: max(th - @layout_overhead, 1),
        status: status,
        transcript: history,
        deltas: "",
        textarea: ExRatatui.textarea_new(),
        history: [],
        history_index: nil,
        pending: pending,
        pending_edit: nil,
        last_error: nil,
        # 0 = follow the tail (auto-scroll); >0 = pinned N lines up
        scroll_offset: 0,
        # tool output blocks collapsed by default ('t' toggles) — same
        # for live execution and resumed history (user request #1)
        open_tool_id: nil,
        reasoning: "",
        test_pid: Keyword.get(opts, :test_pid)
      }

      if prompt, do: send(self(), {:__run__, prompt})

      {:ok, initial}
    end
  end

  # Returns {:ok, pid, restored_state | nil} — the restored state (when
  # resuming) is what seeds the transcript so old messages are visible.
  defp start_session(id, opts) do
    persisted =
      case Keyword.get(opts, :resume_id) do
        nil ->
          nil

        resume_id ->
          # prefix resolution ("1730" -> "tui-1730..."); a failed resume
          # must ABORT, not silently start a fresh session
          case Store.resolve_id(resume_id) do
            {:ok, full_id} -> Store.load(full_id)
            {:error, reason} -> {:error, reason}
          end
      end

    case persisted do
      {:ok, state} ->
        with {:ok, pid} <-
               Supervisor.start_session(
                 id: state.id,
                 context: state.context,
                 model: state.model,
                 scope_root: state.scope_root,
                 policy: state.policy
               ) do
          {:ok, pid, state}
        end

      _ ->
        with {:ok, pid} <-
               Supervisor.start_session(
                 id: id,
                 scope_root: Keyword.get(opts, :scope_root) || File.cwd!()
               ) do
          {:ok, pid, nil}
        end
    end
  end

  # Context messages -> transcript lines. System messages (the framework
  # prompt, AGENTS.md memory) stay hidden; compaction summaries surface
  # as an info line so the user knows the visible history is partial.
  defp restored_history(state) do
    state.context
    |> ReqLLM.Context.to_list()
    |> Enum.flat_map(fn
      # the compaction summary is a synthetic user message; surface it
      # as an info line so the visible history reads as partial
      %ReqLLM.Message{role: :user, content: parts} = msg ->
        text = text_of(parts)

        if String.contains?(text, "Conversation summary") do
          [{:info, "· (earlier messages were compacted — summary present)"}]
        else
          [{msg.role, text}]
        end

      %ReqLLM.Message{role: :assistant, content: parts} ->
        [{:assistant, text_of(parts)}]

      %ReqLLM.Message{role: :tool, name: name, content: parts} ->
        # proper 4-tuple: id-ed, collapsible like live tool entries
        # (the old 2-tuple fell through normalize_entry to :info — full
        # content, un-toggleable; that was the vertical-space bug on
        # resume)
        [{:tool, "tool-r#{System.unique_integer([:positive])}", name, text_of(parts)}]

      %ReqLLM.Message{role: :system, content: parts} ->
        if String.contains?(text_of(parts), "Conversation summary"),
          do: [{:info, "· (earlier messages were compacted — summary present)"}],
          else: []

      _ ->
        []
    end)
    |> Enum.reject(fn entry -> entry_text(entry) == "" end)
  end

  defp text_of(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp text_of(c) when is_binary(c), do: c
  defp text_of(_), do: ""

  # a one-line human summary of a turn failure reason (stream error
  # maps nest the transport cause; keep it short for the transcript)
  defp error_text(%ReqLLM.Error.API.Stream{} = err), do: shorten(err.reason)

  defp error_text(%{reason: reason}) when is_binary(reason), do: shorten(reason)
  defp error_text(reason) when is_binary(reason), do: shorten(reason)
  defp error_text(reason) when is_atom(reason), do: inspect(reason)
  defp error_text(_), do: "unknown error"

  # reason strings embed full inspect dumps (%Finch.TransportError{...});
  # keep the human part
  defp shorten(reason) do
    reason
    |> String.split("%")
    |> List.first()
    |> String.trim()
    |> case do
      "" -> reason
      short -> short
    end
  end

  # Brevity cap for tool output shown expanded: keep head + tail with
  # an elision note in the middle (tails matter for test output; the
  # full content is never far — collapse + reopen is the escape hatch
  # only if the source itself is huge; the session keeps the truth).
  defp cap_lines(text, cap) do
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
    if length(lines) <= cap do
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

  # Visual breathing for markdown answers: ensure ONE blank line after
  # every heading (and one before, unless the heading opens the text).
  # The Markdown widget's own spacing is baked in and tight; this
  # transform is applied once at entry-normalization so measure and
  # render see the same string (heights never drift from it).
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

  defp entry_text({:tool, _id, _name, content}), do: content
  defp entry_text({_role, text}), do: text

  # -- Terminal events -------------------------------------------------------

  @impl true
  def handle_event(%Event.Key{kind: "press"} = ev, state) do
    # two-tier bridge (ADR 011 + the UTF-8 lesson): only special keys
    # and letters the keymap binds become keymap events; everything
    # else is text, forwarded raw to the textarea
    bound = Bridge.bound_letters(Keymap.defaults()) ++ Bridge.bound_letters(decision_keymap())

    case Bridge.translate(ev, bound) do
      {:text, code} ->
        {:noreply, put_in_textarea(state, code)}

      {:key, km_event} ->
        if state.pending != [] do
          handle_decision_key(km_event, state)
        else
          handle_input_key(km_event, ev, state)
        end
    end
  end

  # mouse wheel scrolls the transcript (2 lines per notch, clamped at
  # both ends — see dispatch_input_key scroll_up)
  def handle_event(%Event.Mouse{kind: "scroll_up"}, state) do
    state = clamp_scroll_now(state)

    {:noreply,
     %{state | scroll_offset: min(state.scroll_offset + 2, Map.get(state, :max_scroll, 0))}}
  end

  def handle_event(%Event.Mouse{kind: "scroll_down"}, state) do
    state = clamp_scroll_now(state)
    {:noreply, %{state | scroll_offset: max(state.scroll_offset - 2, 0)}}
  end

  # Click a tool block header → open THAT block (single-open: any other
  # closes automatically — only one id is ever remembered). Click an
  # open block → close. The hit-test recomputes the viewport (a pure
  # function of state) — the same placement math the renderer uses.
  def handle_event(%Event.Mouse{kind: "down", button: "left", y: y}, state) do
    # frame row 0 is the app margin; the transcript occupies the next
    # transcript_visible_height rows
    if y >= 1 and y <= transcript_visible_height(state) do
      case block_at_row(state, y - 1) do
        {:tool, id, _name, _content} ->
          open = if state.open_tool_id == id, do: nil, else: id
          {:noreply, %{state | open_tool_id: open} |> clamp_scroll_now()}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # Terminal dimensions arrive here (and on every actual resize).
  # render/2 sees the frame but CANNOT persist state — every state
  # update computed in render is discarded by the runtime. The
  # last_pane_* values are authoritative only through this handler
  # (found live: dims defaulted to 24/78 forever because render-side
  # persistence was an illusion; the headless tests ran at exactly the
  # default dims and never noticed).
  def handle_event(%Event.Resize{width: width, height: height}, state) do
    state =
      state
      |> Map.put(:last_pane_width, max(width - @width_overhead, 10))
      |> Map.put(:last_pane_height, max(height - @layout_overhead, 1))

    {:noreply, clamp_scroll_now(state)}
  end

  def handle_event(%Event.Paste{content: text}, state) do
    state = put_in_textarea(state, text)
    {:noreply, state}
  end

  def handle_event(_event, state), do: {:noreply, state}

  # In the dialog: y/n/e decide; everything else ignored.
  defp handle_decision_key(km_event, state) do
    case Keymap.resolve(decision_keymap(), km_event) do
      :approve ->
        {:noreply, decide(state, :approve)}

      :reject ->
        {:noreply, decide(state, :reject)}

      :edit ->
        state =
          %{
            state
            | transcript:
                state.transcript ++
                  [{:info, "· arg editing arrives in 5c — use n (reject) for now"}]
          }

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp decision_keymap do
    %{
      approve: [%{key: :y, mod: :none}],
      reject: [%{key: :n, mod: :none}],
      edit: [%{key: :e, mod: :none}]
    }
  end

  # Input area keys: intercept actions BEFORE the textarea consumes them.
  defp handle_input_key(km_event, ev, state) do
    dispatch_input_key(km_event, ev, state)
  end

  defp dispatch_input_key(km_event, ev, state) do
    case Keymap.resolve(Keymap.defaults(), km_event) do
      :toggle_tool_output ->
        state = toggle_last_tool(state)
        state = clamp_scroll_now(state)
        {:noreply, state}

      :scroll_up ->
        # clamp at the top: an offset past the max inflates silently
        # (the screen stops updating but the number keeps growing) and
        # that stale value then makes scroll-down feel dead (found live)
        state = clamp_scroll_now(state)

        {:noreply,
         %{state | scroll_offset: min(state.scroll_offset + 5, Map.get(state, :max_scroll, 0))}}

      :scroll_down ->
        state = clamp_scroll_now(state)
        {:noreply, %{state | scroll_offset: max(state.scroll_offset - 5, 0)}}

      :send_input ->
        {:noreply, send_input(state)}

      :insert_newline ->
        forward_to_textarea(state, ev)

      :history_prev ->
        {:noreply, history_step(state, +1)}

      :history_next ->
        {:noreply, history_step(state, -1)}

      :abort ->
        {:stop, state}

      _ ->
        forward_to_textarea(state, ev)
    end
  end

  defp send_input(state) do
    value = String.trim(ExRatatui.textarea_get_value(state.textarea))

    if value == "" do
      state
    else
      Task.start(fn -> Session.run(state.session_id, value) end)

      %{
        state
        | textarea: ExRatatui.textarea_new(),
          history: [value | state.history],
          history_index: nil,
          transcript: state.transcript ++ [{:user, value}],
          status: :running,
          scroll_offset: 0
      }
    end
  end

  # decide/2 is a GenServer.call that runs the ENTIRE rest of the turn
  # (LLM round-trips included) — calling it inline would freeze the TUI
  # exactly when the dialog must stay responsive. Run it in a Task; the
  # reply arrives via handle_info({:__decided__, ...}).
  defp decide(state, decision) when decision in [:approve, :reject] do
    sid = state.session_id

    decisions =
      Enum.map(state.pending, fn %{id: id} -> %{id: id, decision: decision} end)

    parent = self()

    Task.start(fn ->
      result =
        case Session.decide(sid, decisions) do
          {:ok, session_state} -> {:ok, session_state.status}
          {:error, reason} -> {:error, reason}
        end

      send(parent, {:__decided__, result})
    end)

    # optimistic UI: dialog closes now, real status arrives with the reply
    %{state | pending: [], pending_edit: nil, status: :running}
  end

  defp forward_to_textarea(state, ev) do
    state = put_in_textarea(state, ev)
    {:noreply, state}
  end

  # The textarea state is a mutable NIF resource: textarea_handle_key
  # returns :ok and mutates in place, so we keep the same reference.
  defp put_in_textarea(state, %Event.Key{} = ev) do
    _ = ExRatatui.textarea_handle_key(state.textarea, ev.code, ev.modifiers || [])
    state
  end

  defp put_in_textarea(state, text) when is_binary(text) do
    # raw text (UTF-8) or bracketed paste: insert at the cursor
    # (native API, in-place)
    _ = ExRatatui.textarea_insert_str(state.textarea, text)
    state
  end

  defp history_step(_state, _dir) do
    # 5c: history navigation through the textarea value setter
    # (needs a value+cursor setter pair; deferred)
  end

  # -- Session events --------------------------------------------------------

  @impl true
  def handle_info({:__decided__, {:ok, status}}, state) do
    {:noreply, %{state | status: status}}
  end

  def handle_info({:__decided__, {:error, reason}}, state) do
    {:noreply, %{state | last_error: reason, status: :error}}
  end

  def handle_info({:agent, {:llm_deltas, delta}}, state) do
    {:noreply, %{state | deltas: state.deltas <> delta}}
  end

  def handle_info({:agent, {:status_changed, status}}, state) do
    {:noreply, %{state | status: status}}
  end

  # :interrupted carries the pending calls as detail — this is how the
  # TUI learns WHAT to render in the approval dialog (a live interrupt
  # during a run; attaching mid-session pulls state on mount instead).
  def handle_info({:agent, {:status_changed, :interrupted, pending}}, state) do
    {:noreply, %{state | status: :interrupted, pending: pending}}
  end

  def handle_info({:agent, {:status_changed, :error, reason}}, state) do
    # a failed turn (e.g. provider down) becomes a visible transcript
    # line, not a raw logger dump over the alternate screen
    msg =
      "✖ turn failed: #{error_text(reason)} — the session is idle again; check the provider (ollama up? key set?) and retry"

    {:noreply, %{state | status: :error, transcript: state.transcript ++ [{:info, msg}]}}
  end

  def handle_info({:agent, {:status_changed, status, _detail}}, state) do
    {:noreply, %{state | status: status}}
  end

  def handle_info({:agent, {:llm_message, text}}, state) do
    # the UI transcript stores the DISPLAY shape (breathed markdown):
    # measure and render must never see different strings. The core
    # session keeps the full-fidelity text.
    {:noreply,
     %{
       state
       | transcript: state.transcript ++ [{:assistant, breathe(text)}],
         deltas: "",
         reasoning: ""
     }}
  end

  # agent thinking: streamed BEFORE the answer arrives; shown as a dim
  # transient block and dropped when the turn's text lands
  def handle_info({:agent, {:reasoning_deltas, delta}}, state) do
    {:noreply, %{state | reasoning: state.reasoning <> delta}}
  end

  def handle_info({:agent, {:tool_executed, name, content}}, state) do
    id = "tool-#{System.unique_integer([:positive])}"

    # display shape: capped output (head+tail) — the core session
    # keeps the full output
    content = cap_lines(content, @tool_cap)

    {:noreply,
     %{state | transcript: state.transcript ++ [{:tool, id, name, content}], reasoning: ""}}
  end

  def handle_info({:agent, {:context_compacted, _keep}}, state) do
    {:noreply, %{state | transcript: state.transcript ++ [{:info, "· context compacted"}]}}
  end

  def handle_info({:__run__, prompt}, state) do
    Task.start(fn -> Session.run(state.session_id, prompt) end)
    {:noreply, %{state | status: :running, transcript: state.transcript ++ [{:user, prompt}]}}
  end

  # Terminal resize: the local transport dispatches no Resize events,
  # so poll the size (cheap ioctl) and act on changes.
  def handle_info(:__resize_poll__, state) do
    Process.send_after(self(), :__resize_poll__, 500)

    case ExRatatui.terminal_size() do
      {w, h} when is_integer(w) and is_integer(h) ->
        pane_w = max(w - @width_overhead, 10)
        pane_h = max(h - @layout_overhead, 1)

        if state.last_pane_width == pane_w and state.last_pane_height == pane_h do
          {:noreply, state}
        else
          state =
            state
            |> Map.put(:last_pane_width, pane_w)
            |> Map.put(:last_pane_height, pane_h)

          {:noreply, clamp_scroll_now(state)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Rendering -------------------------------------------------------------

  @impl true
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    # breathing: 1 cell of background visible on every side of the app
    # and between the three regions (opencode-comparison lesson: crammed
    # vs airy is margins + spacing, not line height)
    [transcript_area, input_area, status_area] =
      Layout.split(area, :vertical, [{:min, 0}, {:length, @input_height}, {:length, 1}],
        margin: 1,
        spacing: 1
      )

    widgets =
      transcript_widgets(state, transcript_area) ++
        [
          {input_widget(state), input_area},
          {status_widget(state), status_area}
        ]

    widgets ++ dialog_widgets(state, area)
  end

  # Viewport rendering: entries intersecting the pane get placed at
  # pane-relative positions; entries starting above the pane top scroll
  # via the widget's own :scroll (Paragraph/Markdown support it).
  defp transcript_widgets(state, pane) do
    w = content_width(max(pane.width - 2, 10))

    entries =
      (state.transcript ++ streaming_entries(state))
      |> Enum.map(&normalize_entry/1)

    # view-side clamp for THIS frame (persistence happens in the
    # resize handler — render cannot mutate state)
    max_offset =
      max(TranscriptView.total_height(entries, w, state.open_tool_id) - pane.height, 0)

    scroll_offset = min(state.scroll_offset, max_offset)

    {top, selected} =
      TranscriptView.viewport(entries, pane.height, scroll_offset, w, state.open_tool_id)

    selected
    |> Enum.flat_map(fn {entry, cursor, _h} ->
      entry_widgets(entry, w, state.open_tool_id)
      |> Enum.map(fn {widget, wh} -> {widget, wh, cursor} end)
    end)
    |> Enum.map(fn {widget, h, cursor} ->
      skipped = max(top - cursor, 0)
      rel = cursor - top
      y = max(pane.y + rel, pane.y)
      # clip the bottom at the pane edge
      avail = pane.height - (y - pane.y)
      h = max(min(h, avail), 1)

      # Bordered widgets (open tools, user frames) must not RE-ANCHOR
      # at the pane top when partially scrolled out: the box would
      # repaint its top border forever while its content scrolled away
      # ('empty lines at the end of the block', found live). When the
      # entry's own top rows are already above the pane, drop the
      # border chrome that has scrolled out and window the content:
      # the box EXITS through the top instead of sticking to it.
      # the border rows are skipped FIRST (they are the entry's top
      # chrome), then any remaining skipped rows scroll the content —
      # compute the border allowance BEFORE stripping it
      chrome = border_rows(widget)
      widget = window_border(widget, skipped)
      widget = apply_scroll(widget, max(skipped - chrome, 0))

      {widget, %Rect{x: column_x(pane, w), y: y, width: w, height: h}}
    end)
  end

  # Rows of border chrome a widget carries at its top (for windowing).
  # :all must expand — `:top in [:all]` is false, which cost the ▾ row
  # of an open tool when the box straddled the pane top (found live).
  defp border_rows(%Paragraph{block: %Block{borders: [:all]}}), do: 1

  defp border_rows(%Paragraph{block: %Block{borders: sides}}),
    do: if(:top in sides, do: 1, else: 0)

  defp border_rows(_), do: 0

  # When `skipped` rows of the entry are above the pane, the top border
  # is one of them: paint the remaining rows as a borderless window.
  defp window_border(widget, skipped) do
    case widget do
      %Paragraph{block: %Block{} = block} when skipped > 0 ->
        # :all must expand before stripping — rejecting against [:all]
        # strips nothing (found live: the box kept repainting while its
        # content scrolled away)
        sides =
          case block.borders do
            [:all] -> [:top, :left, :right, :bottom]
            sides -> sides
          end

        sides = Enum.reject(sides, &(&1 in [:top, :left, :right]))

        %{
          widget
          | block: %{
              block
              | borders: sides,
                title: nil,
                title_position: :top
            }
        }

      _ ->
        widget
    end
  end

  # The reading column: capped at @measure, centered on wide panes.
  # Measurement and rendering share this width (heights must match).
  defp content_width(w), do: min(w, @measure)

  defp column_x(pane, w) do
    pane.x + 1 + div(max(pane.width - 2 - w, 0), 2)
  end

  # Immediate scroll clamp on toggle: collapsing can shrink the content
  # extent below the current scroll offset; without this, pgdown has to
  # burn through the stale offset before the view moves (found live).
  defp clamp_scroll_now(state) do
    entries =
      (state.transcript ++ streaming_entries(state))
      |> Enum.map(&normalize_entry/1)

    pane_height =
      if is_integer(state.last_pane_height), do: state.last_pane_height, else: 24

    pane_width =
      content_width(if is_integer(state.last_pane_width), do: state.last_pane_width, else: 78)

    max_offset =
      max(
        TranscriptView.total_height(entries, pane_width, state.open_tool_id) - pane_height,
        0
      )

    state
    |> Map.put(:scroll_offset, min(Map.get(state, :scroll_offset, 0), max_offset))
    |> Map.put(:max_scroll, max_offset)
  end

  # viewport scrolling happens inside the widget when the entry starts
  # above the pane top (Paragraph/Markdown both support :scroll)
  defp apply_scroll(%Paragraph{} = p, 0), do: p
  defp apply_scroll(%Paragraph{} = p, n), do: %{p | scroll: {n, 0}}
  defp apply_scroll(%Markdown{} = m, 0), do: m
  defp apply_scroll(%Markdown{} = m, n), do: %{m | scroll: {n, 0}}
  defp apply_scroll(w, _n), do: w

  # One widget per entry (v1): heights are single-widget, computed via
  # TranscriptView.height.
  defp entry_widgets({:user, text}, w, _te) do
    h = TranscriptView.height({:user, text}, w, nil)

    widget = %Paragraph{
      text: text,
      style: %Style{fg: :white},
      block: %Block{
        title: " you ",
        borders: [:all],
        border_type: :rounded,
        # signaling color: blue receded into the transcript noise —
        # magenta reads as "the user's voice" and separates from the
        # status colors (green running / yellow approval / red error)
        border_style: %Style{fg: :magenta, modifiers: [:bold]},
        padding: {1, 1, 1, 1}
      }
    }

    [{widget, h}]
  end

  defp entry_widgets({:reasoning, text}, w, _te) do
    h = TranscriptView.height({:reasoning, text}, w, nil) - TranscriptView.air()

    widget = %Paragraph{
      text: "· thinking: " <> text,
      style: %Style{fg: :dark_gray, modifiers: [:italic]}
    }

    [{widget, h}]
  end

  defp entry_widgets({:assistant, text}, w, _te) do
    # placement height includes the air rows; the widget rect covers
    # the content only, so the air rows below stay background
    h = TranscriptView.height({:assistant, text}, w, nil) - TranscriptView.air()

    [%Markdown{content: text, style: %Style{fg: :white}, wrap: true}]
    |> List.update_at(0, &{&1, max(h, 1)})
  end

  defp entry_widgets({:tool, id, name, content}, _w, open_id) when id != open_id do
    line = "▸ #{name}: #{first_line(content)}"

    [{%Paragraph{text: line, style: %Style{fg: :dark_gray}}, 1}]
  end

  defp entry_widgets({:tool, id, name, content}, w, _open_id) do
    # rect covers content + border rows only (h - air); the air rows
    # below stay background — same convention as assistant entries
    h = TranscriptView.height({:tool, id, name, content}, w, id) - TranscriptView.air()

    widget = %Paragraph{
      text: "▾ #{name}\n" <> content,
      style: %Style{fg: :dark_gray},
      block: %Block{
        title: " tool output ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray}
      }
    }

    [{widget, h}]
  end

  defp entry_widgets({:info, text}, _w, _te) do
    [{%Paragraph{text: "  " <> text, style: %Style{fg: :dark_gray}}, 1}]
  end

  # (info rects stay 1 row; the air below is background)

  defp first_line(text), do: text |> String.split("\n") |> List.first() |> String.slice(0, 80)

  # transient stream entries: thinking first (dim), the in-flight
  # answer after it (with cursor); both clear when the final message
  # lands (llm_message handler)
  defp streaming_entries(%{deltas: "", reasoning: ""}), do: []

  defp streaming_entries(%{deltas: "", reasoning: r}) when r != "", do: [{:reasoning, r}]

  defp streaming_entries(%{deltas: d, reasoning: r}) do
    if(r == "", do: [], else: [{:reasoning, r}]) ++ [{:assistant, d <> "▌"}]
  end

  defp normalize_entry({:tool, id, name, content}), do: {:tool, id, name, content}
  defp normalize_entry({:user, t}), do: {:user, t}
  defp normalize_entry({:assistant, t}), do: {:assistant, t}
  defp normalize_entry({:reasoning, t}), do: {:reasoning, t}
  defp normalize_entry({:info, t}), do: {:info, t}
  defp normalize_entry({:tool, line}) when is_binary(line), do: {:info, line}

  # The transcript pane shows a WINDOW of the lines: the last
  # `pane_height` lines when scroll_offset is 0 (auto-follow), else a
  # window ending scroll_offset lines above the bottom (scrolled back).
  # Overflow beyond the pane is what produced the "writes below the
  # screen" report — Paragraphs clip at their area, so we pre-window.

  defp input_widget(state) do
    %Textarea{
      state: state.textarea,
      placeholder:
        "Message the agent… (enter=newline, alt-enter=send, ctrl-t opens last tool, click to toggle)",
      line_number_style: nil,
      block: %Block{borders: [:all], border_type: :rounded}
    }
  end

  # Transcript rows visible above the input/status areas.
  defp transcript_visible_height(state) do
    if is_integer(state.last_pane_height), do: state.last_pane_height, else: 24
  end

  # Which entry covers screen row `y` (transcript-pane-relative)?
  # Recomputes the same placement the renderer produces this frame.
  defp block_at_row(state, y) do
    entries =
      (state.transcript ++ streaming_entries(state))
      |> Enum.map(&normalize_entry/1)

    w = content_width(if is_integer(state.last_pane_width), do: state.last_pane_width, else: 78)
    ph = transcript_visible_height(state)

    {_top, selected} =
      TranscriptView.viewport(entries, ph, state.scroll_offset, w, state.open_tool_id)

    # selected: [{entry, cursor, h}] — cursor is absolute (from the
    # BOTTOM). Screen row = (entry_bottom - 1) - y where entry_bottom
    # counts from the pane top... easier: walk from the pane bottom.
    total = TranscriptView.total_height(entries, w, state.open_tool_id)
    top = max(total - ph - state.scroll_offset, 0)

    Enum.find_value(selected, fn {entry, cursor, h} ->
      rel_top = cursor - top
      rel_bottom = rel_top + h - 1

      if y >= rel_top and y <= rel_bottom, do: entry
    end)
  end

  # ctrl-t: open the most recent tool block (or close it if it is open).
  defp toggle_last_tool(state) do
    case Enum.reverse(state.transcript) |> Enum.find(&match?({:tool, _, _, _}, &1)) do
      {:tool, id, _, _} ->
        open = if state.open_tool_id == id, do: nil, else: id
        %{state | open_tool_id: open} |> clamp_scroll_now()

      nil ->
        state
    end
  end

  defp status_widget(state) do
    # scroll diagnostics (live debugging): entries / measured total /
    # offset / expand state — visible in the status line
    entries =
      (state.transcript ++ streaming_entries(state))
      |> Enum.map(&normalize_entry/1)

    w = content_width(if is_integer(state.last_pane_width), do: state.last_pane_width, else: 78)
    ph = if is_integer(state.last_pane_height), do: state.last_pane_height, else: 24
    total = TranscriptView.total_height(entries, w, state.open_tool_id)

    open =
      if state.open_tool_id, do: "open:#{state.open_tool_id}", else: "tools shut"

    diag =
      "scroll: #{state.scroll_offset}/#{max(total - ph, 0)} (#{length(entries)} entries, " <>
        "#{open}, " <>
        "h: #{ph} w: #{w})"

    {glyph, color} =
      case state.status do
        :running -> {"●", :light_green}
        :idle -> {"○", :gray}
        :interrupted -> {"⏸", :yellow}
        :error -> {"✖", :red}
        _ -> {"?", :gray}
      end

    status_text =
      case state.status do
        :running -> "running…"
        :idle -> "idle"
        :interrupted -> "approval needed (y/n/e)"
        :error -> "error"
        other -> inspect(other)
      end

    line =
      Text.Line.new([
        Text.Span.new("#{state.session_id}  ", style: %Style{fg: :gray}),
        Text.Span.new(glyph, style: %Style{fg: color, modifiers: [:bold]}),
        Text.Span.new(" #{status_text}  ", style: %Style{fg: color}),
        Text.Span.new(diag, style: %Style{fg: :dark_gray})
      ])

    %Paragraph{text: [line], style: %Style{bg: :dark_gray}, block: nil}
  end

  # Approval dialog: one bordered box per pending call, args pretty-printed.
  defp dialog_widgets(%{pending: []}, _area), do: []

  defp dialog_widgets(%{pending: pending}, area) do
    pending
    |> Enum.with_index()
    |> Enum.map(fn {call, i} ->
      {_id, name, args} = call_info(call)

      body =
        "#{name}(#{pretty_args(args)})\n\n" <>
          "y = approve   n = reject   e = edit (soon)"

      widget = %Paragraph{
        text: body,
        style: %Style{fg: :white},
        block: %Block{
          title: " APPROVAL #{i + 1}/#{length(pending)} ",
          borders: [:all],
          border_type: :double,
          border_style: %Style{fg: :yellow}
        }
      }

      h = min(6 + length(String.split(pretty_args(args), "\n")), div(area.height, 2))
      rect = %Rect{x: 2, y: area.height - h - 3, width: area.width - 4, height: h}
      {widget, rect}
    end)
  end

  defp call_info(%{id: id, name: name, arguments: args}) when is_map(args),
    do: {id, name, args}

  defp call_info(%ReqLLM.ToolCall{id: id, function: %{name: name, arguments: args_json}}) do
    decoded =
      case Jason.decode(args_json) do
        {:ok, m} -> m
        _ -> %{}
      end

    {id, name, decoded}
  end

  defp pretty_args(args) do
    args
    |> Enum.map(fn {k, v} ->
      v_str = if is_binary(v) and String.contains?(v, "\n"), do: inspect(v), else: to_string(v)
      "#{k}: #{String.slice(v_str, 0, 160)}"
    end)
    |> Enum.join("\n")
  end
end
