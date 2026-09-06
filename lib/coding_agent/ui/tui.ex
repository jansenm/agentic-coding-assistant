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
  alias ExRatatui.Widgets.{Block, Markdown, Paragraph, Textarea}

  @input_height 4

  @impl true
  def mount(opts) do
    id = Keyword.get(opts, :session_id) || "tui-#{System.unique_integer([:positive])}"
    prompt = Keyword.get(opts, :initial_prompt)

    with {:ok, _pid, restored} <- start_session(id, opts) do
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

      initial = %{
        session_id: effective_id,
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
        tools_expanded: false,
        last_pane_height: nil,
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

  # mouse wheel scrolls the transcript (2 lines per notch, clamped)
  def handle_event(%Event.Mouse{kind: "scroll_up"}, state) do
    {:noreply, %{state | scroll_offset: state.scroll_offset + 2}}
  end

  def handle_event(%Event.Mouse{kind: "scroll_down"}, state) do
    {:noreply, %{state | scroll_offset: max(state.scroll_offset - 2, 0)}}
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
        state = %{state | tools_expanded: not state.tools_expanded}
        state = clamp_scroll_now(state)
        {:noreply, state}

      :scroll_up ->
        {:noreply, %{state | scroll_offset: state.scroll_offset + 5}}

      :scroll_down ->
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

  def handle_info({:agent, {:status_changed, status, _detail}}, state) do
    {:noreply, %{state | status: status}}
  end

  def handle_info({:agent, {:llm_message, text}}, state) do
    {:noreply, %{state | transcript: state.transcript ++ [{:assistant, text}], deltas: ""}}
  end

  def handle_info({:agent, {:tool_executed, name, content}}, state) do
    id = "tool-#{System.unique_integer([:positive])}"
    {:noreply, %{state | transcript: state.transcript ++ [{:tool, id, name, content}]}}
  end

  def handle_info({:agent, {:context_compacted, _keep}}, state) do
    {:noreply, %{state | transcript: state.transcript ++ [{:info, "· context compacted"}]}}
  end

  def handle_info({:__run__, prompt}, state) do
    Task.start(fn -> Session.run(state.session_id, prompt) end)
    {:noreply, %{state | status: :running, transcript: state.transcript ++ [{:user, prompt}]}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Rendering -------------------------------------------------------------

  @impl true
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [transcript_area, input_area, status_area] =
      Layout.split(area, :vertical, [{:min, 0}, {:length, @input_height}, {:length, 1}])

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
    w = max(pane.width - 2, 10)

    entries =
      (state.transcript ++ streaming_entries(state))
      |> Enum.map(&normalize_entry/1)

    # clamp the scroll offset to the content extent: toggling collapses
    # shrinks the transcript, and a stale offset beyond the new max pins
    # the view at the top AND makes pgdown unresponsive (found live).
    # The clamp is persistent (state), so the next pgdown is immediate.
    max_offset =
      max(TranscriptView.total_height(entries, w, state.tools_expanded) - pane.height, 0)

    state = %{
      state
      | scroll_offset: min(state.scroll_offset, max_offset),
        last_pane_height: pane.height
    }

    {top, selected} =
      TranscriptView.viewport(entries, pane.height, state.scroll_offset, w, state.tools_expanded)

    selected
    |> Enum.flat_map(fn {entry, cursor, _h} ->
      entry_widgets(entry, w, state.tools_expanded)
      |> Enum.map(fn {widget, wh} -> {widget, wh, cursor} end)
    end)
    |> Enum.map(fn {widget, h, cursor} ->
      rel = cursor - top
      y = max(pane.y + rel, pane.y)
      # clip the bottom at the pane edge
      avail = pane.height - (y - pane.y)
      h = max(min(h, avail), 1)
      widget = apply_scroll(widget, max(top - cursor, 0))
      {widget, %Rect{x: pane.x + 1, y: y, width: w, height: h}}
    end)
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

    max_offset =
      max(
        TranscriptView.total_height(entries, 78, state.tools_expanded) - pane_height,
        0
      )

    %{state | scroll_offset: min(state.scroll_offset, max_offset)}
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
  defp entry_widgets({:user, text}, _w, _te) do
    h = TranscriptView.height({:user, text}, 80, false)

    widget = %Paragraph{
      text: text,
      style: %Style{fg: :white},
      block: %Block{
        title: " you ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :blue}
      }
    }

    [{widget, h}]
  end

  defp entry_widgets({:assistant, text}, _w, _te) do
    h = TranscriptView.height({:assistant, text}, 80, false)

    [%Markdown{content: text, style: %Style{fg: :white}, wrap: true}]
    |> List.update_at(0, &{&1, h})
  end

  defp entry_widgets({:tool, _id, name, content}, _w, false = _te) do
    line = "▸ #{name}: #{first_line(content)}"

    [{%Paragraph{text: line, style: %Style{fg: :dark_gray}}, 1}]
  end

  defp entry_widgets({:tool, _id, name, content}, _w, true) do
    h = TranscriptView.height({:tool, "x", name, content}, 80, true)

    widget = %Paragraph{
      text: "▸ #{name}\n" <> content,
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

  defp first_line(text), do: text |> String.split("\n") |> List.first() |> String.slice(0, 80)

  defp streaming_entries(%{deltas: ""}), do: []

  defp streaming_entries(%{deltas: d}), do: [{:assistant, d <> "▌"}]

  defp normalize_entry({:tool, id, name, content}), do: {:tool, id, name, content}
  defp normalize_entry({:user, t}), do: {:user, t}
  defp normalize_entry({:assistant, t}), do: {:assistant, t}
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
      placeholder: "Message the agent… (enter=newline, alt-enter=send)",
      line_number_style: nil,
      block: %Block{borders: [:all], border_type: :rounded}
    }
  end

  defp status_widget(state) do
    status_text =
      case state.status do
        :running -> "● running…"
        :idle -> "○ idle"
        :interrupted -> "⏸ approval needed (y/n/e)"
        :error -> "✖ error"
        other -> inspect(other)
      end

    # scroll diagnostics (live debugging): entries / measured total /
    # offset / expand state — visible in the status line
    entries =
      (state.transcript ++ streaming_entries(state))
      |> Enum.map(&normalize_entry/1)

    w = 78
    total = TranscriptView.total_height(entries, w, state.tools_expanded)

    diag =
      "scroll: #{state.scroll_offset}/#{max(total - 24, 0)} (#{length(entries)} entries, " <>
        "tools: #{if state.tools_expanded, do: "open", else: "shut"}, h: #{state.last_pane_height || "?"})"

    line = "#{state.session_id}  │  #{status_text}  │  #{diag}"

    %Paragraph{text: line, style: %Style{bg: :dark_gray, fg: :white}, block: nil}
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
