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

  alias CodingAgent.Core.{Compaction, Session}
  alias CodingAgent.Core.Providers.Discovery
  alias CodingAgent.Core.Session.Supervisor
  alias CodingAgent.Core.Session.Store
  alias CodingAgent.UI.{Bridge, Keymap, Menu, TranscriptView}
  alias ExRatatui.Event
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text
  alias ExRatatui.Text
  alias ExRatatui.Widgets.{Block, Clear, Markdown, Paragraph, Textarea}

  # input grows while typing (opencode-style): floor 4 (2 visible
  # lines + border), grows per textarea line, caps at 12
  @input_height 4
  @input_max_height 12
  @tool_cap 30

  # rows the transcript pane loses to chrome: app margin top+bottom (2)
  # + spacing above/below it (2) + input area + status line. Kept in
  # one place so the manual dimension math (mount/poller/resize/clamp)
  # floor variant for state-side math before any render / without a
  # textarea; render-side and live handlers use layout_overhead(state)
  @layout_overhead 2 + 2 + @input_height + 1

  # lines typed -> input height (border included); render and the
  # state-side clamp math MUST agree (the measure/render lesson)
  defp input_height(state) do
    lines =
      if state.textarea,
        do: max(ExRatatui.textarea_line_count(state.textarea), 1),
        else: 2

    min(@input_height - 2 + lines, @input_max_height - 2) + 2
  end

  defp layout_overhead(state), do: 2 + 2 + input_height(state) + 1

  # columns the transcript loses: app margin left+right (2) + the
  # 1-cell inner inset the renderer uses (pane.x + 1 and width - 2)
  @width_overhead 4

  # reading measure (typography): the eye loses the return-sweep past
  # ~100 characters (newspapers/books: 45-90). On wider panes the
  # content column is capped and centered instead of stretching.
  @measure 100

  # right panel width: session name, model, context tokens, % window
  @sidebar_width 24

  @impl true
  def mount(opts) do
    prompt = Keyword.get(opts, :initial_prompt)

    # session picker: when the cwd has previous sessions and no
    # --resume was given, start on the picker (user request: 'on start
    # check if there are previous sessions in the current working
    # directory. If yes go to the session chooser. If not start with a
    # new session.')
    # test_mode skips the picker: tests seed sessions in a shared
    # store dir and expect direct attachment. Opt-in :picker forces
    # it for the picker's own tests.
    test_mode? = Keyword.get(opts, :test_mode) != nil
    force_picker? = Keyword.get(opts, :picker, false)

    if Keyword.get(opts, :resume_id) == nil and (force_picker? or not test_mode?) do
      case Store.list_in(Keyword.get(opts, :scope_root) || File.cwd!()) do
        [_ | _] = sessions ->
          mount_picker(opts, sessions, prompt, Keyword.get(opts, :scope_root) || File.cwd!())

        _ ->
          mount_session(nil, opts, prompt)
      end
    else
      mount_session(nil, opts, prompt)
    end
  end

  # deferred start: the picker deferred session creation; run it now.
  # resume: a chosen id re-runs mount_session with that id AND
  # resume_id (start_session loads the snapshot); fresh: no id.
  defp picker_select(
         %{picker: sessions, picker_index: idx, picker_opts: opts, picker_prompt: prompt},
         action
       ) do
    case action do
      :resume ->
        %{id: chosen} = Enum.at(sessions, idx)
        mount_session(chosen, Keyword.put(opts, :resume_id, chosen), prompt)

      :new ->
        mount_session(nil, opts, prompt)
    end
  end

  defp mount_picker(opts, sessions, prompt, root) do
    {tw, th} =
      case Keyword.get(opts, :test_mode) do
        {w, h} when is_integer(w) and is_integer(h) ->
          {w, h}

        _ ->
          case ExRatatui.terminal_size() do
            {w, h} when is_integer(w) and is_integer(h) -> {w, h}
            _ -> {80, 24}
          end
      end

    initial = %{
      session_id: nil,
      model: nil,
      session_usage: %{input_tokens: 0, output_tokens: 0, cost: nil},
      last_pane_width: max(tw - @width_overhead, 10),
      last_pane_height: max(th - @layout_overhead, 1),
      status: :idle,
      transcript: [],
      deltas: "",
      textarea: ExRatatui.textarea_new(),
      history: [],
      history_index: nil,
      history_draft: nil,
      pending: [],
      pending_edit: nil,
      last_error: nil,
      scroll_offset: 0,
      open_tool_id: nil,
      reasoning: "",
      provider_down?: false,
      test_pid: Keyword.get(opts, :test_pid),
      picker: sessions,
      picker_index: 0,
      picker_opts: opts,
      picker_prompt: prompt,
      picker_op: nil,
      picker_scope: Path.expand(root),
      menu_pending: false,
      menu_popup: nil,
      menu_popup_id: nil,
      menu_index: 0,
      menu_note: nil,
      mount_opts: opts
    }

    {:ok, initial}
  end

  defp mount_session(id, opts, prompt) do
    id = id || Keyword.get(opts, :session_id) || "tui-#{System.unique_integer([:positive])}"

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

      # startup reachability check (design A: a minimal completion
      # through req_llm — provider-agnostic, no endpoint ping). Once at
      # start only: 'if it disappears while using the app i got
      # unlucky'. Skipped in test_mode — tests are LLM-free.
      unless Keyword.get(opts, :test_mode) do
        # the session's model (a resumed session keeps its snapshot's model)
        model =
          case Session.state(effective_id) do
            {:ok, st} -> st.model
            _ -> CodingAgent.model()
          end

        # broadcast on the EFFECTIVE id — a resumed session keeps its
        # persisted id and that is what the view subscribed to (the
        # probe on the mount id was silently lost for --resume runs,
        # found live: 'It still shows idle')
        CodingAgent.UI.ProviderHealth.check_async(model, effective_id)
      end

      # resumed sessions render their history: the persisted context
      # becomes transcript lines (system prompts stay hidden)
      history = (restored && restored_history(restored)) || []

      # ctrl-p recall seeds from the restored context's user prompts
      # (compaction summaries excluded) so an attached old session can
      # walk back through its past messages
      recall = (restored && restored_recall(restored)) || []

      {tw, th} = initial_size

      # the session's ACTUAL model (opts may have been defaulted inside
      # Session.init): mirrored so the model menu marks "(current)"
      session_model =
        case Session.state(effective_id) do
          {:ok, st} -> st.model
          _ -> nil
        end

      initial = %{
        session_id: effective_id,
        model: session_model,
        session_usage:
          (restored && Map.get(restored, :usage)) ||
            %{input_tokens: 0, output_tokens: 0, cost: nil},
        last_pane_width: max(tw - @width_overhead, 10),
        last_pane_height: max(th - @layout_overhead, 1),
        status: status,
        transcript: history,
        deltas: "",
        textarea: ExRatatui.textarea_new(),
        history: recall,
        history_index: nil,
        history_draft: nil,
        pending: pending,
        pending_edit: nil,
        last_error: nil,
        # 0 = follow the tail (auto-scroll); >0 = pinned N lines up
        scroll_offset: 0,
        # tool output blocks collapsed by default ('t' toggles) — same
        # for live execution and resumed history (user request #1)
        open_tool_id: nil,
        reasoning: "",
        provider_down?: false,
        test_pid: Keyword.get(opts, :test_pid),
        # loaded ONCE here, not per keypress (file I/O + TOML parse in
        # the input hot path was the crash vector for a broken live
        # config). Reload points: session switch, picker actions —
        # everything that re-runs mount_session.
        keymap: Keymap.load(),
        # picker mode fields (nil = not in picker mode; set by
        # mount_picker only)
        picker: nil,
        picker_index: 0,
        picker_opts: nil,
        picker_prompt: nil,
        picker_op: nil,
        picker_scope: nil,
        # menu mode: :menu_pending (a prefix chord was pressed, the
        # next letter within @menu_timeout fires the item directly) or
        # a popup map (navigate/enter). nil = normal input.
        menu_pending: false,
        menu_popup: nil,
        menu_popup_id: nil,
        menu_index: 0,
        menu_note: nil,
        # keymap comes from mount_session's initial state (the picker
        # hands off before any normal key reaches the keymap paths)
        mount_opts: opts
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
        # fresh session: the configured default (config.toml or
        # AGENT_MODEL). No default in code (user decision) — a missing
        # one is a hard error naming the config file, until the model
        # menu replaces it with warning + in-session pick
        case CodingAgent.model() do
          nil ->
            {:error,
             {:no_model,
              "no model configured. Set model = \"provider:model\" in " <>
                CodingAgent.Core.UserConfig.global_dir() <>
                "/config.toml (or a project .coding-agent/config.toml), " <>
                "or override per run with AGENT_MODEL"}}

          model ->
            with {:ok, pid} <-
                   Supervisor.start_session(
                     id: id,
                     scope_root: Keyword.get(opts, :scope_root) || File.cwd!(),
                     model: model
                   ) do
              {:ok, pid, nil}
            end
        end
    end
  end

  # user prompts from the restored context, oldest first — the recall
  # list ctrl-p walks (newest-first recall, so oldest-first storage).
  # compaction summaries are synthetic, not user input.
  defp restored_recall(state) do
    state.context
    |> ReqLLM.Context.to_list()
    |> Enum.flat_map(fn
      %ReqLLM.Message{role: :user, content: parts} = msg ->
        text = text_of(parts)

        if String.contains?(text, "Conversation summary") or msg.name == "tool" do
          []
        else
          [text]
        end

      _ ->
        []
    end)
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
  # maps nest the transport cause; keep it short for the transcript).
  # The session wraps stream failures as {:stream_error, struct} —
  # match the wrapper first (the bare-struct clause never fired and
  # every failure read 'unknown error', found live).
  # live report: the tool-loop limit killed a real task's turn and the
  # transcript showed the generic provider hint — say what happened
  defp error_text({:tool_loop_limit, n}),
    do: "tool loop limit (#{n} rounds) reached — task needs more steps"

  defp error_text({:stream_error, %ReqLLM.Error.API.Stream{} = err}), do: shorten(err.reason)

  defp error_text(%ReqLLM.Error.API.Stream{} = err), do: shorten(err.reason)

  defp error_text(%{reason: reason}) when is_binary(reason), do: shorten(reason)
  defp error_text(reason) when is_binary(reason), do: shorten(reason)
  defp error_text(reason) when is_atom(reason), do: inspect(reason)
  defp error_text(_), do: "check the provider (ollama up? key set?)"

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
    if Map.get(state, :picker) do
      handle_picker_key(ev, state)
    else
      handle_menu_or_normal_key(ev, state)
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

  # Click a closed tool block header → open THAT block (single-open: any other
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
      |> Map.put(:last_pane_height, max(height - layout_overhead(state), 1))

    {:noreply, clamp_scroll_now(state)}
  end

  def handle_event(%Event.Paste{content: text}, state) do
    state = put_in_textarea(state, text)
    {:noreply, state}
  end

  def handle_event(_event, state), do: {:noreply, state}

  # Click a to  # -- Picker keys -----------------------------------------------------------
  # up/down/j/k move; enter resumes the selection; n starts fresh;
  # q quits; d deletes (y confirms), r renames (type + enter). While a
  # confirm/rename prompt is up, keys route to it, not the list.
  defp handle_picker_key(%Event.Key{code: "up"}, %{picker_op: nil} = state) do
    idx = max(state.picker_index - 1, 0)
    {:noreply, %{state | picker_index: idx}}
  end

  defp handle_picker_key(%Event.Key{code: "down"}, %{picker_op: nil} = state) do
    idx = min(state.picker_index + 1, length(state.picker) - 1)
    {:noreply, %{state | picker_index: idx}}
  end

  defp handle_picker_key(%Event.Key{code: "enter"}, %{picker_op: nil} = state) do
    case picker_select(state, :resume) do
      {:ok, st} -> {:noreply, st}
      {:error, reason} -> {:noreply, %{state | last_error: inspect(reason)}}
    end
  end

  defp handle_picker_key(%Event.Key{code: "q"}, %{picker_op: nil} = state) do
    # quit from the picker: no session was created, nothing to clean
    {:stop, :normal, state}
  end

  defp handle_picker_key(%Event.Key{code: "n"}, %{picker_op: nil} = state) do
    case picker_select(state, :new) do
      {:ok, st} -> {:noreply, st}
      {:error, reason} -> {:noreply, %{state | last_error: inspect(reason)}}
    end
  end

  defp handle_picker_key(%Event.Key{code: "d"}, %{picker_op: nil} = state) do
    case Enum.at(state.picker, state.picker_index) do
      nil ->
        {:noreply, state}

      s ->
        # arm the destructive action; y commits, anything else cancels
        {:noreply, %{state | picker_op: {:delete, s.id}}}
    end
  end

  defp handle_picker_key(%Event.Key{code: "r"}, %{picker_op: nil} = state) do
    case Enum.at(state.picker, state.picker_index) do
      nil ->
        {:noreply, state}

      s ->
        # rename mode: typed keys build the new name (see the text
        # clause below), enter commits, esc cancels
        {:noreply, %{state | picker_op: {:rename, s.id, ""}}}
    end
  end

  defp handle_picker_key(%Event.Key{code: "y"}, %{picker_op: {:delete, id}} = state) do
    :ok = CodingAgent.Core.Session.Store.delete(id)
    sessions = CodingAgent.Core.Session.Store.list_in(state.picker_scope)

    cond do
      sessions == [] ->
        # nothing left to pick: start fresh
        case picker_select(%{state | picker: []}, :new) do
          {:ok, st} -> {:noreply, st}
          {:error, reason} -> {:noreply, %{state | last_error: inspect(reason)}}
        end

      true ->
        idx = min(state.picker_index, length(sessions) - 1)
        {:noreply, %{state | picker: sessions, picker_index: idx, picker_op: nil}}
    end
  end

  defp handle_picker_key(%Event.Key{code: "y"}, state) do
    {:noreply, state}
  end

  defp handle_picker_key(%Event.Key{code: "escape"}, %{picker_op: prompt} = state)
       when prompt != nil do
    {:noreply, %{state | picker_op: nil}}
  end

  defp handle_picker_key(%Event.Key{code: "esc"}, %{picker_op: prompt} = state)
       when prompt != nil do
    {:noreply, %{state | picker_op: nil}}
  end

  defp handle_picker_key(%Event.Key{code: "enter"}, %{picker_op: {:rename, id, buf}} = state) do
    case CodingAgent.Core.Session.Store.rename(id, buf) do
      {:ok, _new_id} ->
        sessions = CodingAgent.Core.Session.Store.list_in(state.picker_scope)
        idx = min(state.picker_index, max(length(sessions) - 1, 0))
        {:noreply, %{state | picker: sessions, picker_index: idx, picker_op: nil}}

      {:error, reason} ->
        {:noreply, status_note(%{state | picker_op: nil}, "rename failed: #{inspect(reason)}")}
    end
  end

  defp handle_picker_key(%Event.Key{code: code}, %{picker_op: {:rename, id, buf}} = state)
       when binary_part(code, 0, 1) == code and byte_size(code) == 1 do
    # printable single chars (incl. digits, dash, dot, underscore) build the name
    {:noreply, %{state | picker_op: {:rename, id, buf <> code}}}
  end

  defp handle_picker_key(%Event.Key{code: "backspace"}, %{picker_op: {:rename, id, buf}} = state) do
    {:noreply,
     %{state | picker_op: {:rename, id, String.slice(buf, 0, max(String.length(buf) - 1, 0))}}}
  end

  defp handle_picker_key(_ev, state) do
    # unknown keys in picker mode: ignored (safe default)
    {:noreply, state}
  end

  defp handle_normal_key(ev, state) do
    # two-tier bridge (ADR 011 + the UTF-8 lesson): only special keys
    # and letters the keymap binds become keymap events; everything
    # else is text, forwarded raw to the textarea
    bound = Bridge.bound_letters(state.keymap) ++ Bridge.bound_letters(decision_keymap())

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

  # Menu popup overlay (pending note is on the status line, popup is
  # a Clear-backed list box — same pattern as the picker).
  defp menu_widgets(%{menu_popup: nil}, _area), do: []

  defp menu_widgets(state, area) do
    items = state.menu_popup.items

    rows =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, i} ->
        marker = if i == state.menu_index, do: "❯ ", else: "  "

        label =
          cond do
            # session rows (switch popup): id + status
            Map.get(item, :status) != nil -> "#{item.id}  #{item.status}"
            # keymap info rows carry the full text in the action
            match?({:__info__, _}, Map.get(item, :action)) -> elem(item.action, 1)
            true -> Map.get(item, :label) || ""
          end

        key = Map.get(item, :key) || ""
        "#{marker}#{String.pad_trailing(key, 3)}#{label}"
      end)

    body = ([" " <> state.menu_popup.title] ++ rows) |> Enum.join("\n")

    h = min(length(rows) + 3, area.height - 4)
    w = min(60, area.width - 4)
    x = div(max(area.width - w, 0), 2)
    y = area.height - h - 3
    rect = %Rect{x: x, y: y, width: w, height: h}

    widget = %Paragraph{
      text: body,
      style: %Style{fg: :white, bg: :dark_gray},
      block: %Block{
        title: " menu ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan, bg: :dark_gray}
      }
    }

    [{%Clear{}, rect}, {widget, rect}]
  end

  # switch attach: delegate to mount_session (start_session returns
  # {:ok, pid} for already-running sessions — keep-alive switching is
  # free: the GenServer stays up, we swap the view)
  defp attach_selected_session(%{id: id}, state) do
    opts = state.mount_opts || []

    case mount_session(id, Keyword.put(opts, :resume_id, id), nil) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, reason} -> {:noreply, status_note(state, "switch failed: #{inspect(reason)}")}
    end
  end

  # -- Menu helpers -----------------------------------------------------------
  # transient note on the status line (menu prompts); cleared on the
  # next key event
  defp status_note(state, text), do: %{state | menu_note: text}

  # the "show all keymaps" popup: one row per binding, grouped
  defp keymap_popup(keymap) do
    rows =
      Enum.flat_map(keymap, fn {action, patterns} ->
        patterns
        |> Enum.map(&pattern_text/1)
        |> Enum.join(", ")
        |> then(fn keys -> [%{action: {:__info__, "#{keys}  #{action}"}, key: "", label: ""}] end)
      end)

    %{id: :keymaps, title: " keymaps  (esc=close)", items: rows}
  end

  defp pattern_text(%{key: k, mod: :none}), do: to_string(k)
  defp pattern_text(%{key: k, mod: mod}), do: "#{mod}-#{k}"

  # switch session: popup listing the OTHER sessions for this cwd
  # (plus the current one, marked). Keep-alive: the current session's
  # GenServer stays up in the supervisor; attach swaps the view.
  defp switch_session_popup(state) do
    # the CURRENT session's scope is the cwd (picker_opts is nil
    # outside picker mode)
    root =
      case Session.state(state.session_id) do
        {:ok, st} -> st.scope_root
        _ -> File.cwd!()
      end

    sessions = Store.list_in(root)

    others =
      Enum.reject(sessions, fn %{id: id} -> id == state.session_id end)

    if others == [] do
      {:noreply, status_note(%{state | menu_pending: false}, "no other sessions for this cwd")}
    else
      {:noreply,
       %{
         state
         | menu_popup: %{
             id: :switch_session,
             title: " switch session  (arrows, enter=attach, esc=cancel)",
             items: others
           },
           menu_popup_id: :switch_session,
           menu_pending: false,
           menu_index: 0
       }}
    end
  end

  # model switch popup: one item per candidate model. Items are plain
  # maps ({id, source}) — the selection handler switches the session.
  # `current` is marked so the owner sees where they are.
  defp model_popup(state) do
    provider = provider_of(state)

    {:ok, %{entries: entries, note: note}} =
      Discovery.models_cached(provider, provider_config_of(state))

    items =
      Enum.map(entries, fn %{id: id, source: source} ->
        mark = if state.model == "#{provider}:#{id}", do: " (current)", else: ""

        %{
          id: "#{provider}:#{id}",
          label: "#{id}#{mark}" <> if(source == :discovered, do: "  (live)", else: ""),
          status: nil,
          action: :model_selected
        }
      end)

    # the session's CURRENT model is always listed (and marked) — even
    # when discovery is down it must be switchable-back-to
    current =
      case state.model do
        m when is_binary(m) and m != "" ->
          if Enum.any?(items, &(&1.id == m)) do
            nil
          else
            %{
              id: m,
              label: String.replace(m, "#{provider}:", "") <> " (current)",
              status: nil,
              action: :model_selected
            }
          end

        _ ->
          nil
      end

    items =
      if(current, do: [current | items], else: items)
      |> then(fn
        [] -> [%{id: nil, label: "(no models found)", status: nil, action: :noop}]
        items -> items
      end)

    title =
      case note do
        nil -> " switch model  (arrows, enter=switch, esc=cancel)"
        n -> " switch model  (#{String.slice(n, 0, 40)})"
      end

    {:noreply,
     %{
       state
       | menu_popup: %{id: :switch_model, title: title, items: items},
         menu_popup_id: :switch_model,
         menu_pending: false,
         menu_index: 0
     }}
  end

  defp provider_of(state) do
    case String.split(state.model || "", ":", parts: 2) do
      [p, _] -> p
      _ -> "ollama"
    end
  end

  defp provider_config_of(state) do
    case Session.state(state.session_id) do
      {:ok, st} -> st.provider_config || %{}
      _ -> %{}
    end
  end

  # -- Menu mode (ctrl-x prefix) ----------------------------------------------
  # :menu_pending = the next letter fires the item directly; the timer
  # (:__menu_timeout__) flips the popup on when the owner just waits.
  # esc or an unbound letter cancels (letters go to the textarea).
  @menu_timeout 1_000

  # ctrl-x: enter pending mode; the timer turns it into the popup.
  # NOT while the menu popup is open (the popup owns the keys) and not
  # in pending already (re-press = cancel, like a toggle).
  defp handle_menu_or_normal_key(
         %Event.Key{code: "x", modifiers: ["ctrl"]} = _ev,
         %{
           menu_pending: false,
           menu_popup: nil
         } = state
       ) do
    # ctrl-x: enter pending mode; the timer turns it into the popup
    Process.send_after(self(), :__menu_timeout__, @menu_timeout)

    state =
      %{state | menu_pending: true}
      |> status_note("menu: press a letter… (or wait for the list)")

    {:noreply, state}
  end

  defp handle_menu_or_normal_key(ev, %{menu_pending: true} = state) do
    # any key while pending: consume the prefix. A letter with a
    # command fires it directly; everything else falls through to
    # normal handling (typing must not be eaten).
    case Menu.resolve(Menu.main_menu(), ev.code) do
      nil ->
        {:noreply, %{state | menu_pending: false}}

      item ->
        state = %{state | menu_pending: false}

        # needs_popup items whose target list is TUI-owned
        # (switch_session opens the session list) route through
        # run_menu_action; Menu's placeholder popup is unused for them
        run_menu_action(item.action, state)
    end
  end

  defp handle_menu_or_normal_key(ev, state) do
    # any key clears the transient menu note
    state = %{state | menu_note: nil}

    if Map.get(state, :menu_popup) do
      handle_menu_popup_key(ev, state)
    else
      handle_normal_key(ev, state)
    end
  end

  # timer fired: the owner waited -> show the popup instead of the
  # fast path (id nil: the MAIN menu, whose items carry actions)
  defp open_menu_popup(popup, state) do
    # the popup's own id distinguishes target-picking popups
    # (switch_session) from plain menus (the main menu: nil)
    id = if Map.get(popup, :id) == :main, do: nil, else: Map.get(popup, :id)

    %{state | menu_popup: popup, menu_popup_id: id, menu_index: 0, menu_pending: false}
  end

  # popup navigation
  defp handle_menu_popup_key(%Event.Key{code: "up"}, state) do
    idx = max(state.menu_index - 1, 0)
    {:noreply, %{state | menu_index: idx}}
  end

  defp handle_menu_popup_key(%Event.Key{code: "down"}, state) do
    items = state.menu_popup.items
    idx = min(state.menu_index + 1, length(items) - 1)
    {:noreply, %{state | menu_index: idx}}
  end

  defp handle_menu_popup_key(%Event.Key{code: "enter"}, state) do
    selected = Enum.at(state.menu_popup.items, state.menu_index)
    state = %{state | menu_popup: nil}

    case state.menu_popup_id do
      :switch_session -> attach_selected_session(selected, state)
      :switch_model -> model_selected(selected, state)
      _ -> run_menu_action(selected.action, state)
    end
  end

  # crossterm decodes Esc as "esc" (events.rs:78); accept both spellings
  defp handle_menu_popup_key(%Event.Key{code: code}, state)
       when code in ["esc", "escape"] do
    {:noreply, %{state | menu_popup: nil, menu_popup_id: nil}}
  end

  defp handle_menu_popup_key(_ev, state), do: {:noreply, state}

  defp run_menu_action(:switch_session, state), do: switch_session_popup(state)

  # model switch: catalog (req_llm) + discovered (GET, dialect per
  # provider entry) candidates, cached per mount. Never blocks the TUI
  # longer than the discovery timeout; a dead server = a note, and the
  # popup still opens (with whatever resolved).
  defp run_menu_action(:switch_model, state), do: model_popup(state)

  defp run_menu_action(:toggle_tool_output, state) do
    {:noreply, toggle_last_tool(state)}
  end

  defp run_menu_action(:quit, state), do: {:stop, :normal, state}

  defp run_menu_action(:show_keymaps, state) do
    {:noreply,
     %{state | menu_popup: keymap_popup(state.keymap), menu_popup_id: :keymaps, menu_index: 0}}
  end

  defp run_menu_action(_other, state), do: {:noreply, state}

  # popup selection: switch THIS session's wire model for the next
  # turn (Session.set_model). The noop placeholder row (empty list)
  # just closes.
  defp model_selected(%{id: nil}, state), do: {:noreply, state}

  defp model_selected(%{id: model}, state) do
    case Session.set_model(state.session_id, model) do
      :ok ->
        # state.model mirrors the session (render + next switch marks
        # "(current)" correctly)
        {:noreply, status_note(%{state | model: model}, "model → #{model}")}

      other ->
        {:noreply, status_note(state, "model switch failed: #{inspect(other)}")}
    end
  end

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
    case Keymap.resolve(state.keymap, km_event) do
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
    # typing can grow the input box (opencode-style) — the transcript
    # pane height changes with it, so re-derive pane dims like the
    # resize handler does (measure/render agreement)
    {:noreply, rederive_pane(state)}
  end

  defp rederive_pane(state) do
    case ExRatatui.terminal_size() do
      {w, h} when is_integer(w) and is_integer(h) ->
        pane_w = max(w - @width_overhead, 10)
        pane_h = max(h - layout_overhead(state), 1)

        if state.last_pane_width == pane_w and state.last_pane_height == pane_h do
          state
        else
          state
          |> Map.put(:last_pane_width, pane_w)
          |> Map.put(:last_pane_height, pane_h)
          |> clamp_scroll_now()
        end

      _ ->
        state
    end
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

  # 5c: history navigation through the textarea value setter.
  # idx is the current recall position (nil = at live input); saving the
  # live draft the first time you step back makes ctrl-n land home again
  defp history_step(%{history: []} = state, _dir), do: state

  defp history_step(state, dir) do
    n = length(state.history)
    idx = if state.history_index == nil, do: -1, else: state.history_index
    idx = idx + dir
    idx = min(max(idx, -1), n - 1)

    cond do
      idx == -1 ->
        # back to the live draft (saved when first stepping back)
        draft = Map.get(state, :history_draft) || ""
        ExRatatui.textarea_set_value(state.textarea, draft)
        %{state | history_index: nil}

      state.history_index == nil ->
        # leaving the live input: remember the draft
        draft = ExRatatui.textarea_get_value(state.textarea)
        value = Enum.at(state.history, idx)
        ExRatatui.textarea_set_value(state.textarea, value)
        %{state | history_index: idx, history_draft: draft}

      true ->
        value = Enum.at(state.history, idx)
        ExRatatui.textarea_set_value(state.textarea, value)
        %{state | history_index: idx}
    end
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

  # startup provider check (ProviderHealth): down -> a red status and
  # a transcript line BEFORE the user asks anything; up while an
  # error is showing -> the provider is back
  def handle_info({:agent, {:provider_status, :down, reason}}, state) do
    msg = "✖ provider unavailable: #{reason} — turns will fail until it is reachable"

    {:noreply,
     %{
       state
       | status: :error,
         transcript: state.transcript ++ [{:info, msg}],
         provider_down?: true
     }}
  end

  def handle_info({:agent, {:usage_updated, usage}}, state) do
    {:noreply, %{state | session_usage: usage}}
  end

  def handle_info({:agent, {:provider_status, :up}}, state) do
    if state.status == :error and Map.get(state, :provider_down?, false) do
      {:noreply, %{state | status: :idle, provider_down?: false}}
    else
      {:noreply, state}
    end
  end

  # broadcast info notes (compaction warnings, notices): dim transcript line
  def handle_info({:agent, {:info, text}}, state) do
    {:noreply, %{state | transcript: state.transcript ++ [{:info, text}]}}
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
  # transient block and dropped when the turn's text lands.
  #
  # Live report (clarified): the LINES rendered fine, but every delta
  # appended an empty line at the END — the box filled with blank rows
  # as the thinking streamed. Squeezing the DELTA misses the case where
  # GLM sends "\n" and "" deltas separately (l1\n + \n = l1\n\n ACROSS
  # deltas). Squeeze the ACCUMULATED string instead, and strip the
  # trailing newline(s): the @air row owns the spacing after the block,
  # so trailing blanks only grow the box toward a screen of empty lines.
  def handle_info({:agent, {:reasoning_deltas, delta}}, state) do
    reasoning =
      (state.reasoning <> delta)
      |> String.replace("\r", "")
      |> String.replace("\n\n", "\n")
      |> String.replace_trailing("\n\n", "\n")

    {:noreply, %{state | reasoning: reasoning}}
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
  def handle_info(:__menu_timeout__, %{menu_pending: true} = state) do
    # the owner waited: show the popup instead of the fast path
    {:noreply, open_menu_popup(Menu.main_menu(), %{state | menu_pending: false})}
  end

  def handle_info(:__menu_timeout__, state) do
    # pending was consumed by a key that raced the timer — nothing to do
    {:noreply, state}
  end

  def handle_info(:__resize_poll__, state) do
    Process.send_after(self(), :__resize_poll__, 500)

    case ExRatatui.terminal_size() do
      {w, h} when is_integer(w) and is_integer(h) ->
        pane_w = max(w - @width_overhead, 10)
        pane_h = max(h - layout_overhead(state), 1)

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
  # picker mode: mount deferred session creation (Map.get — a struct
  # pattern %{picker: ...} raises KeyError against snapshots/state
  # maps that predate the field, the struct-update lesson)
  def render(state, frame) do
    if Map.get(state, :picker) do
      area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
      picker_widgets(state, area)
    else
      render_main(state, frame)
    end
  end

  defp render_main(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    # breathing: 1 cell of background visible on every side of the app
    # and between the three regions (opencode-comparison lesson: crammed
    # vs airy is margins + spacing, not line height)
    # status row on the very bottom; sidebar + input span the full
    # height (sidebar: whole window per user feedback), the input pane
    # is only as wide as the input (not full width) and grows with the
    # typed lines (opencode-style)
    [main_area, status_area] =
      Layout.split(area, :vertical, [{:min, 0}, {:length, 1}],
        margin: 1,
        spacing: 1
      )

    [sidebar_area, mid_area] =
      Layout.split(main_area, :horizontal, [
        {:length, @sidebar_width},
        {:min, 0}
      ])

    in_h = input_height(state)

    # input pane width: capped at the reading measure so a wide
    # terminal doesn't stretch the input full width (user feedback)
    [mid_area, _air_area] =
      Layout.split(mid_area, :horizontal, [{:length, min(@measure, mid_area.width)}, {:min, 0}])

    [transcript_area, input_area] =
      Layout.split(mid_area, :vertical, [{:min, 0}, {:length, in_h}], spacing: 1)

    widgets =
      transcript_widgets(state, transcript_area) ++
        [
          {sidebar_widget(state), sidebar_area},
          {input_widget(state), input_area},
          {status_widget(state), status_area}
        ]

    widgets ++ menu_widgets(state, area) ++ dialog_widgets(state, area)
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

  defp sidebar_widget(state) do
    usage = Map.get(state, :session_usage) || %{input_tokens: 0, output_tokens: 0, cost: nil}
    window = Application.get_env(:coding_agent, :context_window_tokens, 500_000)

    trigger =
      Application.get_env(
        :coding_agent,
        :compaction_trigger_tokens,
        Compaction.default_trigger_tokens()
      )

    cfg = CodingAgent.Core.UserConfig.load(nil)
    model = cfg.config["model"] || Application.get_env(:coding_agent, :model)

    effort =
      cfg.config["reasoning_effort"] || Application.get_env(:coding_agent, :reasoning_effort)

    # last turn's context size (ground truth from the provider) drives
    # the % line; cumulative totals are separate
    last_in = Map.get(usage, :last_input_tokens, 0)
    pct = trunc(last_in * 100 / max(window, 1))

    # pre-compaction notice territory: 80%+ of the trigger → visible warning
    pct_style =
      if last_in >= trunc(trigger * 0.8), do: %Style{fg: :yellow}, else: %Style{fg: :dark_gray}

    lines = [
      Text.Line.new([Text.Span.new("session", style: %Style{fg: :dark_gray})]),
      Text.Line.new([
        Text.Span.new(String.slice(state.session_id, 0, 22), style: %Style{fg: :white})
      ]),
      Text.Line.new([Text.Span.new("", style: %Style{})]),
      Text.Line.new([Text.Span.new("model", style: %Style{fg: :dark_gray})]),
      Text.Line.new([
        Text.Span.new(String.slice(model || "?", 0, 22), style: %Style{fg: :white})
      ]),
      Text.Line.new([
        Text.Span.new(
          "effort: #{effort || "default"}",
          style: %Style{fg: :dark_gray}
        )
      ]),
      Text.Line.new([Text.Span.new("", style: %Style{})]),
      Text.Line.new([Text.Span.new("context", style: %Style{fg: :dark_gray})]),
      Text.Line.new([
        Text.Span.new(
          "#{fmt_k(Map.get(usage, :input_tokens, 0))} tok in",
          style: %Style{fg: :white}
        )
      ]),
      Text.Line.new([
        Text.Span.new(
          "#{fmt_k(Map.get(usage, :output_tokens, 0))} tok out",
          style: %Style{fg: :white}
        )
      ]),
      Text.Line.new([
        Text.Span.new(
          "#{fmt_k(last_in)} ctx (#{pct}% win)",
          style: pct_style
        )
      ]),
      Text.Line.new([
        Text.Span.new("compacts at #{fmt_k(trigger)} tok", style: pct_style)
      ])
    ]

    cost_line =
      case usage[:cost] do
        c when is_number(c) and c > 0 ->
          Text.Line.new([Text.Span.new("$#{Float.round(c, 4)}", style: %Style{fg: :white})])

        _ ->
          nil
      end

    lines =
      if(cost_line, do: lines ++ [cost_line], else: lines) ++
        [
          Text.Line.new([Text.Span.new("", style: %Style{})]),
          Text.Line.new([
            Text.Span.new("ctrl-t toggles tools", style: %Style{fg: :dark_gray})
          ])
        ]

    %Paragraph{
      text: lines,
      style: %Style{},
      block: %Block{
        title: " agent ",
        borders: [:right],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray}
      }
    }
  end

  defp fmt_k(n) when n < 1000, do: "#{n}"
  defp fmt_k(n), do: "#{trunc(n / 100) / 10}k"

  defp status_widget(state) do
    note = Map.get(state, :menu_note)
    if note, do: status_widget_note(state, note), else: status_widget_plain(state)
  end

  defp status_widget_note(_state, note) do
    # menu prompt replaces the scroll diagnostics while visible
    line = Text.Line.new([Text.Span.new(note, style: %Style{fg: :yellow})])
    %Paragraph{text: [line], style: %Style{bg: :dark_gray}, block: nil}
  end

  defp status_widget_plain(state) do
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

    down? = Map.get(state, :provider_down?, false)

    {glyph, color, label} =
      case state.status do
        :running -> {"●", :light_green, "running…"}
        :idle -> {"○", :gray, "idle"}
        :interrupted -> {"⏸", :yellow, "approval needed (y/n/e)"}
        :error -> {"✖", :red, if(down?, do: "provider unavailable", else: "error")}
        _ -> {"?", :gray, "unknown"}
      end

    status_text = label

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
  # Session picker (mount-time): list the cwd's previous sessions,
  # newest first; enter resumes, n starts fresh, q quits. The
  # selected row is highlighted; each row shows the id, age, status.
  defp picker_widgets(state, area) do
    rows =
      state.picker
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        marker = if i == state.picker_index, do: "❯ ", else: "  "

        status = s.status |> to_string() |> String.pad_trailing(8)

        "#{marker}#{String.slice(s.id, 0, 22)}  #{status}  " <>
          "#{format_age(s.saved_at)}"
      end)

    header =
      case state.picker_op do
        {:delete, id} ->
          " Delete #{id}?  (y=confirm, any other key cancels)"

        {:rename, _id, buf} ->
          " Rename to: #{buf}  (enter=commit, esc=cancel)"

        nil ->
          " Pick a session:  (enter=resume, n=new, d=delete, r=rename, q=quit)"
      end

    body = ([header] ++ rows) |> Enum.join("\n")

    h = min(length(state.picker) + 3, area.height - 4)
    w = min(60, area.width - 4)
    x = div(max(area.width - w, 0), 2)
    y = div(max(area.height - h, 0), 2)
    rect = %Rect{x: x, y: y, width: w, height: h}

    widget = %Paragraph{
      text: body,
      style: %Style{fg: :white, bg: :dark_gray},
      block: %Block{
        title: " sessions ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan, bg: :dark_gray}
      }
    }

    [{%Clear{}, rect}, {widget, rect}]
  end

  defp format_age(%DateTime{} = dt) do
    mins = div(DateTime.diff(DateTime.utc_now(), dt), 60)

    cond do
      mins < 1 -> "now"
      mins < 60 -> "#{mins}m ago"
      mins < 1440 -> "#{div(mins, 60)}h ago"
      true -> "#{div(mins, 1440)}d ago"
    end
  end

  defp dialog_widgets(%{pending: []}, _area), do: []

  defp dialog_widgets(%{pending: pending}, area) do
    pending
    |> Enum.with_index()
    |> Enum.map(fn {call, i} ->
      {_id, name, args} = call_info(call)

      text =
        "#{name}(#{pretty_args(args)})\n\n" <>
          "y = approve   n = reject   e = edit (soon)"

      h = min(6 + length(String.split(pretty_args(args), "\n")), div(area.height, 2))

      # NOTE: widget-level bg + Clear variants both failed headless
      # (bg didn't fill; Clear killed the render cycle). The joined
      # string with per-row spaces renders — bg comes from the
      # widget-level style.
      body =
        text
        |> String.split("\n")
        |> Enum.concat(List.duplicate(" ", max(h - 2 - length(String.split(text, "\n")), 0)))
        |> Enum.join("\n")

      widget = %Paragraph{
        text: body,
        style: %Style{fg: :white, bg: :dark_gray},
        block: %Block{
          title: " APPROVAL #{i + 1}/#{length(pending)} ",
          borders: [:all],
          border_type: :double,
          border_style: %Style{fg: :yellow, bg: :dark_gray}
        }
      }

      # cap at the reading measure and center: a wide terminal must
      # not stretch the dialog edge to edge (live report)
      w = min(@measure + 2, area.width - 4)
      x = div(max(area.width - w, 0), 2)
      rect = %Rect{x: x, y: area.height - h - 3, width: w, height: h}
      [{%Clear{}, rect}, {widget, rect}]
    end)
    |> List.flatten()
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
