defmodule CodingAgent.UI.Tui do
  @moduledoc """
  The phase-5 terminal UI driver (5a render foundation + 5b interaction).

  Layout: transcript pane (scrollable) / live band (what the RUNNING turn
  is doing) / composer panel (input field + its setup meta row). The band
  and the composer are separate rows because they answer separate
  questions: the band names the agent and model EXECUTING the turn, the
  composer's row names the ones the NEXT input will use — Tab switches the
  latter while a running turn keeps its own. Input is an ExRatatui
  Textarea — enter inserts a newline (ADR 011 composition-first default);
  alt-enter sends the buffer to the agent. The ADR 011 keymap is the
  action table; UI.Bridge translates terminal events; UI.Keymap resolves
  actions.

  Approval flow (ADR 010): when the gate interrupts, the pending calls
  render as a dialog; y approves, n rejects, e edits — per-key editing
  of single-line values in the dialog (multiline values shown
  read-only; the CLI limitation does not recur: paste is a terminal
  event here, and args render pretty-printed).
  """

  use ExRatatui.App

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Providers.Discovery
  alias CodingAgent.Core.ToolCall
  alias CodingAgent.Core.Session.Compactor
  alias CodingAgent.Core.Session.Store
  alias CodingAgent.Core.Session.Supervisor
  alias CodingAgent.Core.Session.Usage

  alias CodingAgent.UI.{
    Bridge,
    Composer,
    Editor,
    Keymap,
    LiveBand,
    Menu,
    Styles,
    TranscriptView
  }

  alias ExRatatui.Event
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Clear, Markdown, Paragraph}

  @tool_cap 30
  # how long an armed esc-to-quit stays armed (ms)
  @quit_confirm_window 3_000
  # how long an armed esc-to-stop stays armed (ms): esc is pressed out of
  # habit in text fields (vim muscle memory), so a lone esc must never
  # stop a running turn — a second esc within this window does
  @stop_confirm_window 1_500
  @thinking_cap 12

  # Streaming deltas DEFER their render and a timer coalesces them: the
  # provider emits hundreds of tiny deltas, so painting per delta buried
  # keys behind a render train (the interaction hang). A delta folds the
  # text and returns `render?: false`; a separate tick paints at most one
  # frame per window, so input is handled in the normal loop between
  # frames instead of waiting behind a render. 60ms reads as live (~16fps)
  # without letting per-frame cost dominate a long stream.
  @stream_render_ms 60
  @stream_render_tick :__stream_render__

  # The activity spinner: a calm ~8fps, driven by a subscription that is
  # declared only while a turn is busy.
  @spin_ms 120
  @spin_tick :__spin__

  # rows the transcript pane loses to chrome: app margin top+bottom (2)
  # + spacing above/below it (2) + the live band + composer panel. Kept
  # in one place so the manual dimension math
  # (mount/poller/resize/clamp) agrees with the layout; render-side and
  # live handlers use layout_overhead(state). The heights live in
  # `UI.LiveBand.height/0` and `UI.Composer.height/1` (measure = paint).
  @layout_overhead 2 + 2 + LiveBand.height() + Composer.min_height()

  defp input_height(state), do: Composer.height(composer(state))

  # The subagent tab bar (ADR 018) takes one row above the transcript when
  # it is present (measure = paint, ADR 028): the pane height must drop by
  # that row, or the viewport over-reserves and the last line clips.
  defp layout_overhead(state) do
    tab_h = if map_size(Map.get(state, :subagents, %{})) > 0, do: 1, else: 0
    2 + 2 + LiveBand.height() + input_height(state) + tab_h
  end

  # The room every OVERLAY (menu, approval, budget, doom, question) has:
  # the rows above the live band. An overlay may cover the transcript (the
  # least costly surface) but never the input field or the band — the band
  # is the running turn's status, and a dialog that hid it would hide the
  # one row the owner asked to keep in sight.
  #
  # One function for both the cap and the placement, because they are the
  # same number: an overlay's height is clamped to this room and its
  # bottom edge IS this room's last row. Two separate offsets is how the
  # menu popup ended up placed at a negative row (a 26-row popup on a
  # 30-row window, measured live as `draw error: rect.y unexpected
  # value`).
  #
  # The heights are MEASURED, not assumed: a grown input pushes the band
  # up and the overlays move with it. The fixed `area.height - 4` cap and
  # `area.height - h - 3` offset this replaces only worked while the row
  # they must not cover was the composer's own meta row.
  defp overlay_room(state, area) do
    max(area.height - input_height(state) - LiveBand.height() - 2, 1)
  end

  # an overlay's rect: bottom edge on the room's last row, centered
  # horizontally, at most as tall as the room
  defp overlay_rect(state, area, h, w) do
    h = min(h, overlay_room(state, area))

    %Rect{
      x: div(max(area.width - w, 0), 2),
      y: overlay_room(state, area) - h,
      width: w,
      height: h
    }
  end

  # columns the transcript loses: app margin left+right (2) + the
  # 1-cell inner inset the renderer uses (pane.x + 1 and width - 2)
  @width_overhead 4

  # reading measure (typography): the eye loses the return-sweep past
  # ~100 characters (newspapers/books: 45-90). On wider panes the
  # content column is capped and centered instead of stretching.
  @measure 100

  # left panel width: session name, model, context tokens, % window.
  # Widened from 24 after live use: model ids ("ollama_cloud:glm-5.3-flash")
  # were cut mid-name. Toggleable at runtime (Menu :toggle_sidebar, the
  # footer hint shows the chord); hidden leaves the panel out of the
  # layout entirely rather than painting an empty column.
  @sidebar_width 36

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
  # resume: the SELECTED (visible) session re-runs mount_session with
  # that id AND resume_id (start_session loads the snapshot); fresh: no
  # id. Selection reads the same `picker_visible/1` the render uses.
  defp picker_select(%{picker_opts: opts, picker_prompt: prompt} = state, action) do
    case action do
      :resume ->
        case picker_selected(state) do
          nil -> {:error, :no_selection}
          %{id: chosen} -> mount_session(chosen, Keyword.put(opts, :resume_id, chosen), prompt)
        end

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
      session_usage: CodingAgent.Core.Session.Usage.new(),
      last_pane_width: max(tw - @width_overhead, 10),
      last_pane_height: max(th - @layout_overhead, 1),
      status: :idle,
      transcript: [],
      # esc-to-quit confirm: first esc arms, second esc (within
      # @quit_confirm_window) quits, any other key disarms
      quit_confirm?: false,
      quit_armed_at: 0,
      # esc-to-stop confirm: while a turn runs, first esc arms, second esc
      # (within @stop_confirm_window) stops, any other key disarms
      stop_confirm?: false,
      stop_armed_at: 0,
      # in-flight stream, IN ARRIVAL ORDER: a list of
      # {:reasoning, text} | {:assistant, text} blocks. Reasoning and
      # answer text interleave exactly as the provider streamed them
      # (opencode-style) instead of two buffers that force reasoning
      # first; cleared/persisted when the turn's message lands.
      stream: [],
      # true while a delta landed but its frame has not painted; drives
      # subscriptions/1 (the stream render throttle)
      stream_dirty?: false,
      # Activity/spinner state: the last message from the session that
      # shows progress (any delta, a tool start/finish). The spinner
      # reports how long the app has been silent, so a stuck turn visibly
      # diverges from a healthy one.
      last_activity_at: nil,
      spin: 0,
      # the tool currently running (from {:tool_started, name}), nil when
      # none — lets the status read "running mix".
      active_tool: nil,
      tool_started_at: nil,
      # scroll diagnostics are developer output (they render in the
      # composer's meta row when on); off by default, toggled with
      # ctrl-x d.
      debug_visible?: false,
      textarea: ExRatatui.textarea_new(),
      history: [],
      history_index: nil,
      history_draft: nil,
      pending: [],
      pending_edit: nil,
      # true from pressing y/n until the {:__decided__} reply lands:
      # the dialog is hidden but `pending` is NOT dropped, so an
      # errored decide/2 can re-show it
      deciding?: false,
      # the tool-round budget prompt (ADR 025): %{budget: n} while the
      # session is parked at the budget; y continues, n stops
      budget_prompt: nil,
      # the doom-loop prompt (ADR 026): %{tool: name} while the session is
      # parked at a repeated call; y continues, n rejects (steers)
      doom_prompt: nil,
      # the question prompt (ADR 027): %{questions: [...], answers: [...],
      # index: i, selected: [j], custom: nil|buf} while the agent waits for
      # an answer; a wizard, one question per screen
      question_prompt: nil,
      # subagent tabs (ADR 018): child_id => child state (identity,
      # transcript, stream, finished?). The live band names the leaf of
      # the active delegation. Empty until a `task` call starts a child.
      subagents: %{},
      active_subagent: nil,
      # the child tab currently shown (nil = the parent transcript). The
      # transcript pane renders this child's own entries read-only.
      active_tab: nil,
      last_error: nil,
      scroll_offset: 0,
      open_tool_id: nil,
      provider_down?: false,
      test_pid: Keyword.get(opts, :test_pid),
      test_mode?: Keyword.get(opts, :test_mode) != nil,
      picker: sessions,
      picker_index: 0,
      picker_opts: opts,
      picker_prompt: prompt,
      picker_op: nil,
      picker_scope: Path.expand(root),
      # Session management (ADR 020, slice 1): the picker is a manager,
      # not just a chooser. `picker_all?` widens the source from this
      # directory's sessions to the whole store; `picker_filter` narrows
      # the visible rows (id / model / status / scope). While the filter
      # prompt is open, `picker_op` is `{:filter, buf}` and routes
      # printable keys into the query.
      picker_all?: false,
      picker_filter: "",
      # store-wide content search (ADR 020 S1): `S` opens a query prompt;
      # while it is committed, the picker source is `Store.search/1`
      # results (sessions with their matching display rows) instead of
      # the metadata listing. `picker_op` is `{:search, buf}` while typing.
      picker_search: nil,
      # sidebar panel: visible by default; toggled at runtime
      # (Menu :toggle_sidebar) or seeded off via `sidebar: false`
      # (tests read a clean transcript buffer without a 36-col panel)
      sidebar_visible?: Keyword.get(opts, :sidebar, true),
      menu_pending: false,
      # the armed `:__menu_timeout__` timer ref (cancelled when the prefix
      # is consumed), so a stale timer cannot steal a later ctrl-x window
      menu_timer: nil,
      menu_popup: nil,
      menu_popup_id: nil,
      menu_index: 0,
      menu_note: nil,
      mount_opts: opts
    }

    {:ok, initial}
  end

  # A parked budget prompt (ADR 025): the TUI renders a continue/stop
  # dialog from %{budget: n}. nil when the session is not at the budget.
  defp budget_prompt_of(%{budget_pause: %{budget: budget}}), do: %{budget: budget}
  defp budget_prompt_of(_), do: nil

  # A parked doom-loop prompt (ADR 026): continue/reject dialog.
  defp doom_prompt_of(%{doom_pause: %{tool: tool}}), do: %{tool: tool}
  defp doom_prompt_of(_), do: nil

  # A parked question (ADR 027): the wizard state. `index` is the current
  # question, `selected` the chosen option indices, `answers` the finished
  # lists, `custom` a free-text buffer when the "type your own" option is
  # active.
  defp question_prompt_of(%{question_pause: %{questions: questions}})
       when is_list(questions) and questions != [] do
    %{questions: questions, index: 0, selected: [], answers: [], custom: nil}
  end

  defp question_prompt_of(_), do: nil

  defp mount_session(id, opts, prompt) do
    id = id || Keyword.get(opts, :session_id) || "tui-#{System.unique_integer([:positive])}"

    with {:ok, _pid, restored, notice} <- start_session(id, opts) do
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

      # resize poll: the local transport dispatches no Resize events, so
      # the live TUI polls the host tty. In test_mode that NIF would read
      # the HOST terminal (nondeterministic) — skip the timer; tests seed
      # deterministic pane dims from the declared size and may fire
      # :__resize_poll__ explicitly.
      unless Keyword.get(opts, :test_mode) do
        Process.send_after(self(), :__resize_poll__, 500)
      end

      # the ACTUAL session id (a resumed session keeps its persisted id)
      effective_id = (restored && restored.id) || id

      Session.subscribe(effective_id)

      # attach to the CURRENT state, not a stale idle assumption: the
      # session may already be running/interrupted (e.g. attached after
      # the gate paused, or resumed from disk)
      {status, pending, budget_prompt, doom_prompt, question_prompt} =
        case Session.state(effective_id) do
          {:ok, st} ->
            {st.status, st.pending_tool_calls, budget_prompt_of(st), doom_prompt_of(st),
             question_prompt_of(st)}

          _ ->
            {:idle, [], nil, nil, nil}
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

      # Resumed sessions render the persisted DISPLAY view (ADR 020):
      # the immutable record including reasoning, which the agent view
      # never held. Old sessions (written before the display view) have
      # no rows and fall back to reconstructing from the context — the
      # lossy behaviour this slice replaces.
      history = (restored && resumed_history(restored.id, restored)) || []
      history = if notice, do: [{:info, notice} | history], else: history

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

      # the session's ACTUAL reasoning effort (ADR 029), mirrored for the
      # sidebar — same reason as the model: the session resolved it from
      # the layered config, so a global re-read here could disagree.
      session_effort =
        case Session.state(effective_id) do
          {:ok, st} -> Map.get(st, :reasoning_effort)
          _ -> nil
        end

      initial = %{
        session_id: effective_id,
        model: session_model,
        # the scope root this session works in, mirrored for the sidebar
        # heading (read once per mount, like the model and the effort — the
        # render path must not call into the session per frame)
        scope_root: session_scope(effective_id),
        # ADR 018 two slots:
        #   running_agent  — what is executing the ACTIVE turn (the
        #                    session's resolved definition; a subagent
        #                    later). nil = no agent.
        #   next_agent     — what the NEXT input starts with. Tab cycles
        #                    the primary agents; a running turn keeps its
        #                    own agent, so the two can differ.
        running_agent: session_agent(effective_id),
        next_agent: session_agent(effective_id),
        # subagent tabs (ADR 018): child_id => child state. The live band
        # names the LEAF of the active delegation while a child runs; a
        # finished tab is KEPT (read-only) until the view is discarded.
        # The child's transcript is never blended into the parent view;
        # `active_tab` selects which transcript the pane renders.
        subagents: %{},
        active_subagent: nil,
        active_tab: nil,
        # the agent executing the CURRENT turn (unknown until the
        # session broadcasts {:turn_started, agent}); used to attribute
        # live assistant/tool/compaction lines while a turn streams.
        active_agent: session_agent(effective_id),
        # per-turn attribution: one agent name (or nil) per USER turn,
        # in execution order. Seeded from the persisted session on
        # resume; extended locally when a prompt is sent (before the
        # session broadcasts its own turn_started) so the just-typed
        # "you" footer can show the target agent immediately.
        turn_agents: session_turn_agents(effective_id),
        primary_agents: primary_agent_names(session_scope(effective_id)),
        # models per slot, resolved once per mount (not per frame — the
        # sidebar runs at poll cadence and must not hit the disk)
        running_agent_model:
          agent_model(session_scope(effective_id), session_agent(effective_id)),
        next_agent_model: agent_model(session_scope(effective_id), session_agent(effective_id)),
        session_usage:
          CodingAgent.Core.Session.Usage.from_map(restored && Map.get(restored, :usage)),
        last_pane_width: max(tw - @width_overhead, 10),
        last_pane_height: max(th - @layout_overhead, 1),
        status: status,
        transcript: history,
        # esc-to-quit confirm: first esc arms, second esc (within
        # @quit_confirm_window) quits, any other key disarms
        quit_confirm?: false,
        quit_armed_at: 0,
        # esc-to-stop confirm: while a turn runs, first esc arms, second
        # esc (within @stop_confirm_window) stops, any other key disarms
        stop_confirm?: false,
        stop_armed_at: 0,
        # in-flight stream, IN ARRIVAL ORDER (see mount_picker)
        stream: [],
        # true while a delta has landed but its frame has not been painted;
        # drives subscriptions/1 (the stream render throttle)
        stream_dirty?: false,
        # activity/spinner + debug state (see mount_picker)
        last_activity_at: nil,
        spin: 0,
        active_tool: nil,
        tool_started_at: nil,
        debug_visible?: false,
        textarea: ExRatatui.textarea_new(),
        history: recall,
        history_index: nil,
        history_draft: nil,
        pending: pending,
        pending_edit: nil,
        deciding?: false,
        budget_prompt: budget_prompt,
        doom_prompt: doom_prompt,
        question_prompt: question_prompt,
        last_error: nil,
        # 0 = follow the tail (auto-scroll); >0 = pinned N lines up
        scroll_offset: 0,
        # tool output blocks collapsed by default ('t' toggles) — same
        # for live execution and resumed history (user request #1)
        open_tool_id: nil,
        provider_down?: false,
        test_pid: Keyword.get(opts, :test_pid),
        test_mode?: Keyword.get(opts, :test_mode) != nil,
        # loaded ONCE here, not per keypress (file I/O + TOML parse in
        # the input hot path was the crash vector for a broken live
        # config). Reload points: session switch, picker actions —
        # everything that re-runs mount_session.
        keymap: Keymap.load(),
        # the sidebar's effort line renders what the SESSION resolved
        # (ADR 029), not a per-frame config re-read
        session_effort: session_effort,
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
        # sidebar panel: visible by default; toggled at runtime
        # (Menu :toggle_sidebar) or seeded off via `sidebar: false`
        # (tests read a clean transcript buffer without a 36-col panel)
        sidebar_visible?: Keyword.get(opts, :sidebar, true),
        menu_pending: false,
        menu_timer: nil,
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

  # Returns {:ok, pid, restored_state | nil, notice | nil} — the restored
  # state (when resuming) seeds the transcript so old messages are
  # visible; the notice is a human line to show at the top (a failed
  # resume that fell back to a fresh session).
  defp start_session(id, opts) do
    case Keyword.get(opts, :resume_id) do
      nil ->
        start_fresh(id, opts, nil)

      resume_id ->
        # prefix resolution ("1730" -> "tui-1730..."). A resume that
        # cannot load does NOT crash the app and does NOT stay silent:
        # it reports why and starts a fresh session (orderly fallback).
        case Store.resolve_id(resume_id) do
          {:ok, full_id} -> start_resumed(Store.load(full_id), id, opts, resume_id)
          {:error, reason} -> start_fresh(id, opts, resume_failure_notice(resume_id, reason))
        end
    end
  end

  # The resume mapping (base policy, restored agent, usage, parked round)
  # lives in Core.Session.resume_opts/2 — the view does not reconstruct
  # State field-by-field.
  defp start_resumed({:ok, state}, _id, _opts, _resume_id) do
    with {:ok, pid} <- Session.resume(state, interactive: true) do
      {:ok, pid, state, nil}
    end
  end

  defp start_resumed({:error, reason}, id, opts, resume_id) do
    start_fresh(id, opts, resume_failure_notice(resume_id, reason))
  end

  # A fresh session: the configured default (config.toml or
  # AGENT_MODEL). No default in code (user decision) — a missing one is
  # a hard error naming the config file, until the model menu replaces
  # it with warning + in-session pick. `notice` (a failed resume) is
  # carried up to render as an info line.
  defp start_fresh(id, opts, notice) do
    case CodingAgent.model() do
      nil ->
        {:error, {:no_model, CodingAgent.Core.Config.no_model_message()}}

      model ->
        with {:ok, pid} <-
               Supervisor.start_session(
                 id: id,
                 scope_root: Keyword.get(opts, :scope_root) || File.cwd!(),
                 model: model,
                 agent: Keyword.get(opts, :agent),
                 # the TUI can answer a mid-turn question: at the round
                 # budget the session ASKS continue/stop (ADR 025) instead
                 # of auto-summarizing
                 interactive: true
               ) do
          {:ok, pid, nil, notice}
        end
    end
  end

  # A friendly, jargon-free line for the transcript when a resume fails.
  defp resume_failure_notice(resume_id, reason) do
    "· could not resume #{resume_id} — #{human_load_error(reason)}; started a fresh session"
  end

  defp human_load_error(:enoent), do: "no such session"
  defp human_load_error({:ambiguous_id, many}), do: "ambiguous id (#{length(many)} match)"
  defp human_load_error({:not_a_session_file, v}), do: "not a session file (format #{inspect(v)})"
  defp human_load_error({:bad_session_state, msg}), do: "unreadable session (#{msg})"
  defp human_load_error(:eacces), do: "permission denied"
  defp human_load_error(other), do: inspect(other)

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

  # The resumed transcript (ADR 020): the persisted display view when the
  # session has one, else the old reconstruction from the agent view.
  # The display view is authoritative — it is the record of what the user
  # saw, including reasoning and the pre-compaction history.
  defp resumed_history(session_id, %{id: _} = restored) do
    case Store.display(session_id) do
      [] ->
        restored_history(restored)

      entries ->
        # drop any entry a future kind does not map (display_entry -> nil)
        entries
        |> Enum.map(&display_entry/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(fn entry -> entry_text(entry) == "" end)
    end
  end

  # One stored display row -> a transcript entry. Kinds mirror the live
  # transcript shapes so the render layer treats resumed and live entries
  # identically. `agent` attribution rides the 3-tuple forms.
  defp display_entry(%{kind: :user, text: t, agent: agent}), do: {:user, t, agent}
  defp display_entry(%{kind: :assistant, text: t, agent: agent}), do: {:assistant, t, agent}
  defp display_entry(%{kind: :reasoning, text: t}), do: {:reasoning, t}
  defp display_entry(%{kind: :info, text: t}), do: {:info, t}

  # tool rows: the meta now carries the call arguments too
  # ({:tool, name, args}); the old 2-tuple form stays for rows written
  # before arguments were recorded. The transcript shows the result, not
  # the args (args live in the export and the approval dialog).
  defp display_entry(%{kind: :tool, text: t, meta: {:tool, name, _args}}),
    do: {:tool, tool_id(), name, t}

  defp display_entry(%{kind: :tool, text: t, meta: {:tool, name}}),
    do: {:tool, tool_id(), name, t}

  defp display_entry(%{kind: :tool, text: t}), do: {:tool, tool_id(), "tool", t}
  defp display_entry(_), do: nil

  defp tool_id, do: "tool-r#{System.unique_integer([:positive])}"

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
  defp error_text({:stream_error, %ReqLLM.Error.API.Stream{} = err}), do: shorten(err.reason)

  defp error_text(%ReqLLM.Error.API.Stream{} = err), do: shorten(err.reason)

  defp error_text(%{reason: reason}) when is_binary(reason), do: shorten(reason)
  defp error_text(reason) when is_binary(reason), do: shorten(reason)
  defp error_text(reason) when is_atom(reason), do: inspect(reason)
  defp error_text(_), do: "check the provider (ollama up? key set?)"

  # Classify a turn failure so the hint is honest (the one classifier
  # lives in Core.Failure; the TUI and ProviderHealth both consume it).
  # The categories:
  #
  #   :local    — the request never left the machine correctly: a
  #               build/encoding failure on OUR side (e.g. an invalid
  #               UTF-8 byte in the context). Naming the provider here is
  #               actively misleading.
  #   :provider — the request reached the wire and the provider/transport
  #               answered badly (connection refused, 401/403, 429, 5xx).
  #   :other    — anything we cannot place; keep the reason, no claim.
  @doc false
  # Public for tests only (like the session's other @doc false helpers).
  def classify_failure(reason), do: CodingAgent.Core.Failure.classify(reason)

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
  defp entry_text({_role, text, _agent}), do: text
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

  # mouse wheel scrolls the transcript (2 lines per notch). The offset is
  # clamped through the viewport (ADR 028): with lazy measurement the
  # maximum is discovered when the walk reaches the top, so there is no
  # stored bound to read — clamping IS the walk.
  def handle_event(%Event.Mouse{kind: "scroll_up"}, state) do
    {:noreply, scroll_active(state, +2) |> clamp_scroll_now()}
  end

  def handle_event(%Event.Mouse{kind: "scroll_down"}, state) do
    {:noreply, scroll_active(state, -2) |> clamp_scroll_now()}
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
          open = if active_open_id(state) == id, do: nil, else: id
          {:noreply, put_open_id(state, open) |> clamp_scroll_now()}

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
    # bracketed paste is text, not a key: route through the same executor
    {:noreply, edit(state, {:text, text})}
  end

  def handle_event(_event, state), do: {:noreply, state}

  # -- Picker source (ADR 020, slice 1) --------------------------------------
  # The picker lists either this directory's sessions (default) or the
  # whole store (`a`), narrowed by a free-text filter (`/`). `picker_visible/1`
  # feeds both the render and the key handlers, so "what is selected" and
  # "what is shown" can never drift. `state.picker` holds the loaded
  # source; it is reloaded on any mutation or source toggle (never on a
  # plain keypress — the store is not a hot path).
  defp picker_visible(state) do
    source = Map.get(state, :picker) || []
    filter = String.trim(Map.get(state, :picker_filter, ""))

    if filter == "" do
      source
    else
      needle = String.downcase(filter)

      Enum.filter(source, fn s ->
        String.downcase("#{s.id} #{s.model || ""} #{s.status} #{s.scope_root || ""}")
        |> String.contains?(needle)
      end)
    end
  end

  # The currently selected row, or nil when the list is empty.
  defp picker_selected(state) do
    Enum.at(picker_visible(state), state.picker_index)
  end

  # Reload the source for the current mode: a committed content search
  # (ADR 020 S1) takes precedence; otherwise this dir vs whole store.
  # Clears the prompt and clamps the selection into range.
  defp picker_reload(state) do
    sessions = picker_source(state)
    idx = min(state.picker_index, max(length(sessions) - 1, 0))
    %{state | picker: sessions, picker_index: max(idx, 0), picker_op: nil}
  end

  # Export the selected session's display view to a file (ADR 020 S3).
  # Destination: the session's scope root when it still exists (the work
  # context, and where a human would look), else the state dir. The name
  # is derived from the session id, which is already a safe filename.
  defp export_selected(state, format) do
    case picker_selected(state) do
      nil ->
        {:noreply, state}

      %{id: id} = meta ->
        case CodingAgent.Core.Session.Export.data(id) do
          {:ok, data} ->
            {ext, body} = render_export(data, format)
            dir = export_dir(meta)
            path = Path.join(dir, "#{id}.#{ext}")

            case File.write(path, body) do
              :ok ->
                {:noreply, status_note(state, "exported #{id} → #{path}")}

              {:error, reason} ->
                {:noreply, status_note(state, "export failed: #{inspect(reason)}")}
            end

          {:error, reason} ->
            {:noreply, status_note(state, "export failed: #{inspect(reason)}")}
        end
    end
  end

  defp render_export(data, :markdown),
    do: {"md", CodingAgent.Core.Session.Export.to_markdown(data)}

  defp render_export(data, :json),
    do: {"json", CodingAgent.Core.Session.Export.to_json(data) <> "\n"}

  defp export_dir(%{scope_root: root}) when is_binary(root) and root != "" do
    if File.dir?(root), do: root, else: CodingAgent.Core.Config.state_dir()
  end

  defp export_dir(_), do: CodingAgent.Core.Config.state_dir()

  # Live search as the query is typed: reload the picker source from the
  # display view on every keystroke (cheap at this scale).
  defp picker_reload_live_search(state, query) do
    sessions = Store.search(query)
    %{state | picker: sessions, picker_search: query, picker_index: 0}
  end

  # The picker's unfiltered source: the search results when a content
  # query is committed, else the metadata listing for the scope.
  defp picker_source(state) do
    case Map.get(state, :picker_search) do
      query when is_binary(query) and query != "" ->
        Store.search(query)

      _ ->
        if Map.get(state, :picker_all?, false) do
          Store.list()
        else
          Store.list_in(state.picker_scope)
        end
    end
  end

  # The ids older than `days`, over the picker's SOURCE (this dir or the
  # whole store), not the filtered view — age cleanup is a management
  # action orthogonal to a display filter.
  defp prune_candidates(state, days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400)

    source =
      if Map.get(state, :picker_all?, false) do
        Store.list()
      else
        Store.list_in(state.picker_scope)
      end

    source
    |> Enum.filter(&(DateTime.compare(&1.saved_at, cutoff) == :lt))
    |> Enum.map(& &1.id)
  end

  # The sessions LARGER than `max_bytes`, over the picker's SOURCE (this
  # dir / whole store), like prune-by-age — a management action orthogonal
  # to a display filter or content search. Sorted LARGEST first, so the
  # biggest offenders go first and the deletion order is honest.
  defp size_prune_candidates(state, max_bytes) do
    source =
      if Map.get(state, :picker_all?, false) do
        Store.list()
      else
        Store.list_in(state.picker_scope)
      end

    source
    |> Enum.filter(&(Map.get(&1, :size, 0) > max_bytes))
    |> Enum.sort_by(&Map.get(&1, :size, 0), :desc)
    |> Enum.map(& &1.id)
  end

  # -- Picker keys -----------------------------------------------------------
  # up/down move; enter resumes; n starts fresh; q quits; d deletes one
  # (y confirms); r renames; `a` toggles this-dir vs whole-store; `/`
  # opens a filter; `D` deletes every VISIBLE session (the directory bulk
  # delete). While a confirm/rename/filter prompt is up, keys route to it.
  defp handle_picker_key(%Event.Key{code: "up"}, %{picker_op: nil} = state) do
    idx = max(state.picker_index - 1, 0)
    {:noreply, %{state | picker_index: idx}}
  end

  defp handle_picker_key(%Event.Key{code: "down"}, %{picker_op: nil} = state) do
    idx = min(state.picker_index + 1, length(picker_visible(state)) - 1)
    idx = max(idx, 0)
    {:noreply, %{state | picker_index: idx}}
  end

  # `a`: widen/narrow the source (this directory <-> the whole store).
  # The selection resets — the row at the same index is a different
  # session once the source changes.
  defp handle_picker_key(%Event.Key{code: "a"}, %{picker_op: nil} = state) do
    state = %{state | picker_all?: not Map.get(state, :picker_all?, false), picker_index: 0}
    {:noreply, picker_reload(state)}
  end

  # `/`: open the filter prompt. Printable keys build it, enter commits
  # (the list is already live-filtered as you type), esc clears+closes.
  defp handle_picker_key(%Event.Key{code: "/"}, %{picker_op: nil} = state) do
    {:noreply, %{state | picker_op: {:filter, ""}, picker_index: 0}}
  end

  # `s`: store-wide CONTENT search (ADR 020 S1) — "in which sessions did I
  # touch X". Distinct from `/` (which narrows the metadata listing): this
  # queries the display view and shows the matching rows. Live as you
  # type (the source reloads each keystroke, cheap at this scale).
  defp handle_picker_key(%Event.Key{code: "s"}, %{picker_op: nil} = state) do
    {:noreply, %{state | picker_op: {:search, ""}, picker_search: "", picker_index: 0}}
  end

  # `D`: delete every VISIBLE session (bulk). This is the directory
  # delete when the source is this-dir, and "filtered set" when the
  # whole store is shown — the confirmation names the count and scope.
  defp handle_picker_key(%Event.Key{code: "D"}, %{picker_op: nil} = state) do
    case picker_visible(state) do
      [] ->
        {:noreply, state}

      visible ->
        ids = Enum.map(visible, & &1.id)
        {:noreply, %{state | picker_op: {:delete_many, ids}}}
    end
  end

  # `P`: prune by age (the old CLI verb `--session-prune <days>`, now
  # that the CLI is being retired). Opens a days prompt, then confirms —
  # destructive, like d/D. Operates on the picker's SOURCE (this dir /
  # whole store), NOT the filtered view: age cleanup is orthogonal to a
  # display filter, and silently pruning only the filtered subset would
  # be a trap.
  defp handle_picker_key(%Event.Key{code: "P"}, %{picker_op: nil} = state) do
    {:noreply, %{state | picker_op: {:prune, ""}}}
  end

  # `S`: prune by SIZE — the retention counterpart to `P` (age). Opens an
  # MB prompt, then confirms. Also operates on the picker's SOURCE, not
  # the filtered/search view (cleanup is orthogonal to display).
  defp handle_picker_key(%Event.Key{code: "S"}, %{picker_op: nil} = state) do
    {:noreply, %{state | picker_op: {:prune_size, ""}}}
  end

  # `e` / `E`: export the SELECTED session as a readable transcript
  # (ADR 020 S3) — Markdown by default, JSON with shift. The file lands
  # in the session's own scope root (where the work happened), named
  # after the session id, so it sits beside the repo it describes.
  defp handle_picker_key(%Event.Key{code: "e"}, %{picker_op: nil} = state) do
    export_selected(state, :markdown)
  end

  defp handle_picker_key(%Event.Key{code: "E"}, %{picker_op: nil} = state) do
    export_selected(state, :json)
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
    case picker_selected(state) do
      nil ->
        {:noreply, state}

      s ->
        # arm the destructive action; y commits, anything else cancels
        {:noreply, %{state | picker_op: {:delete, s.id}}}
    end
  end

  defp handle_picker_key(%Event.Key{code: "r"}, %{picker_op: nil} = state) do
    case picker_selected(state) do
      nil ->
        {:noreply, state}

      s ->
        # rename mode: typed keys build the new name (see the text
        # clause below), enter commits, esc cancels
        {:noreply, %{state | picker_op: {:rename, s.id, ""}}}
    end
  end

  # y confirms a single delete; if the picker now has no sessions at all
  # (this dir AND whole store empty), there is nothing to pick — start
  # fresh instead of leaving a dead picker.
  defp handle_picker_key(%Event.Key{code: "y"}, %{picker_op: {:delete, id}} = state) do
    :ok = Store.delete(id)
    state = picker_reload(state)

    if state.picker == [] do
      case picker_select(state, :new) do
        {:ok, st} -> {:noreply, st}
        {:error, reason} -> {:noreply, %{state | last_error: inspect(reason)}}
      end
    else
      {:noreply, state}
    end
  end

  # y confirms a bulk delete of the VISIBLE set (the directory delete).
  # It never empties the store to auto-start a session — it is a
  # management action, not a selection.
  defp handle_picker_key(%Event.Key{code: "y"}, %{picker_op: {:delete_many, ids}} = state) do
    Enum.each(ids, &Store.delete/1)
    {:noreply, picker_reload(state)}
  end

  # y confirms a prune (by age or by size): delete the armed set. The
  # reason is only used for the (already-shown) prompt text.
  defp handle_picker_key(%Event.Key{code: "y"}, %{picker_op: {:prune_confirm, ids, _why}} = state) do
    Enum.each(ids, &Store.delete/1)
    {:noreply, status_note(picker_reload(state), "pruned #{length(ids)} session(s)")}
  end

  # y with no armed prune is a no-op (mirrors the other confirm clauses).
  defp handle_picker_key(%Event.Key{code: "y"}, %{picker_op: {:prune, _buf}} = state) do
    {:noreply, state}
  end

  defp handle_picker_key(%Event.Key{code: "y"}, %{picker_op: {:prune_size, _buf}} = state) do
    {:noreply, state}
  end

  defp handle_picker_key(%Event.Key{code: "y"}, state) do
    {:noreply, state}
  end

  # Filter prompt esc: unlike the other prompts, esc also CLEARS the
  # filter (it is a live query, not a pending decision). This clause must
  # precede the generic prompt-esc below, which would only close it.
  defp handle_picker_key(%Event.Key{code: code}, %{picker_op: {:filter, _buf}} = state)
       when code in ["escape", "esc"] do
    {:noreply, %{state | picker_op: nil, picker_filter: "", picker_index: 0}}
  end

  # Search prompt esc: like the filter, esc clears the query and closes,
  # restoring the metadata listing (this is a live query, not a pending
  # decision). Must precede the generic prompt-esc below.
  defp handle_picker_key(%Event.Key{code: code}, %{picker_op: {:search, _buf}} = state)
       when code in ["escape", "esc"] do
    {:noreply, picker_reload(%{state | picker_op: nil, picker_search: nil, picker_index: 0})}
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
    case Store.rename(id, buf) do
      {:ok, _new_id} ->
        {:noreply, picker_reload(state)}

      {:error, reason} ->
        {:noreply, status_note(%{state | picker_op: nil}, "rename failed: #{inspect(reason)}")}
    end
  end

  # Filter prompt: enter commits (the list was already filtered live as
  # you typed), esc clears the filter and closes, backspace edits.
  defp handle_picker_key(%Event.Key{code: "enter"}, %{picker_op: {:filter, _buf}} = state) do
    {:noreply, %{state | picker_op: nil, picker_index: 0}}
  end

  # Prune prompt: digits build the age (in days); enter arms the
  # confirmation with the matching session set; backspace edits.
  defp handle_picker_key(%Event.Key{code: code}, %{picker_op: {:prune, buf}} = state)
       when code in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] do
    {:noreply, %{state | picker_op: {:prune, buf <> code}}}
  end

  defp handle_picker_key(%Event.Key{code: "backspace"}, %{picker_op: {:prune, buf}} = state) do
    {:noreply,
     %{state | picker_op: {:prune, String.slice(buf, 0, max(String.length(buf) - 1, 0))}}}
  end

  defp handle_picker_key(%Event.Key{code: "enter"}, %{picker_op: {:prune, buf}} = state) do
    case Integer.parse(String.trim(buf)) do
      {days, ""} when days > 0 ->
        ids = prune_candidates(state, days)

        case ids do
          [] ->
            {:noreply, status_note(%{state | picker_op: nil}, "nothing older than #{days}d")}

          _ ->
            {:noreply, %{state | picker_op: {:prune_confirm, ids, "older than #{days}d"}}}
        end

      _ ->
        {:noreply, %{state | picker_op: nil}}
    end
  end

  # Size-prune prompt: digits build the MB threshold; enter arms the same
  # confirmation the age prompt uses (with a size-flavoured reason).
  defp handle_picker_key(%Event.Key{code: code}, %{picker_op: {:prune_size, buf}} = state)
       when code in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] do
    {:noreply, %{state | picker_op: {:prune_size, buf <> code}}}
  end

  defp handle_picker_key(%Event.Key{code: "backspace"}, %{picker_op: {:prune_size, buf}} = state) do
    {:noreply,
     %{state | picker_op: {:prune_size, String.slice(buf, 0, max(String.length(buf) - 1, 0))}}}
  end

  defp handle_picker_key(%Event.Key{code: "enter"}, %{picker_op: {:prune_size, buf}} = state) do
    case Integer.parse(String.trim(buf)) do
      {mb, ""} when mb > 0 ->
        max_bytes = mb * 1024 * 1024
        ids = size_prune_candidates(state, max_bytes)

        case ids do
          [] ->
            {:noreply, status_note(%{state | picker_op: nil}, "nothing larger than #{mb} MB")}

          _ ->
            {:noreply, %{state | picker_op: {:prune_confirm, ids, "larger than #{mb} MB"}}}
        end

      _ ->
        {:noreply, %{state | picker_op: nil}}
    end
  end

  defp handle_picker_key(%Event.Key{code: "backspace"}, %{picker_op: {:filter, buf}} = state) do
    next = String.slice(buf, 0, max(String.length(buf) - 1, 0))
    {:noreply, %{state | picker_op: {:filter, next}, picker_filter: next, picker_index: 0}}
  end

  defp handle_picker_key(%Event.Key{code: code}, %{picker_op: {:filter, buf}} = state)
       when binary_part(code, 0, 1) == code and byte_size(code) == 1 do
    next = buf <> code
    {:noreply, %{state | picker_op: {:filter, next}, picker_filter: next, picker_index: 0}}
  end

  # Search prompt: enter commits the query (already live); printable
  # keys and backspace rebuild the query and reload the source live. The
  # search esc clause lives up beside the filter esc (both clear their
  # query), before the generic prompt-esc.
  defp handle_picker_key(%Event.Key{code: "enter"}, %{picker_op: {:search, _buf}} = state) do
    {:noreply, %{state | picker_op: nil, picker_index: 0}}
  end

  defp handle_picker_key(%Event.Key{code: "backspace"}, %{picker_op: {:search, buf}} = state) do
    next = String.slice(buf, 0, max(String.length(buf) - 1, 0))
    {:noreply, picker_reload_live_search(%{state | picker_op: {:search, next}}, next)}
  end

  defp handle_picker_key(%Event.Key{code: code}, %{picker_op: {:search, buf}} = state)
       when binary_part(code, 0, 1) == code and byte_size(code) == 1 do
    next = buf <> code
    {:noreply, picker_reload_live_search(%{state | picker_op: {:search, next}}, next)}
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
    # Two-tier bridge (ADR 011 + the UTF-8 lesson): only special keys and
    # letters the keymap binds become keymap events; everything else is
    # TEXT. The decision letters (y/n/e) are control candidates ONLY
    # while the approval dialog is up — outside it they are ordinary
    # typing, so they must not be bound (binding them always made "e"
    # untypable once ADR 021 stopped forwarding unowned keys as text).
    deciding? = state.pending != [] and not Map.get(state, :deciding?, false)
    # the budget/doom/question prompts (ADR 025/026/027) are blocking
    # surfaces; they have no pending tool calls, so they are mutually
    # exclusive with each other and with the approval dialog
    question? = Map.get(state, :question_prompt) != nil

    prompt? =
      Map.get(state, :budget_prompt) != nil or Map.get(state, :doom_prompt) != nil or question?

    bound =
      cond do
        # the question wizard is text-driven (digits, letters, enter); it
        # routes raw events itself, so the keymap is not consulted
        question? -> []
        prompt? -> Bridge.bound_letters(decision_keymap())
        deciding? -> Bridge.bound_letters(state.keymap) ++ Bridge.bound_letters(decision_keymap())
        true -> Bridge.bound_letters(state.keymap)
      end

    case Bridge.translate(ev, bound) do
      {:text, code} ->
        # text input disarms the esc confirms (only esc drives them)
        state = %{state | quit_confirm?: false, stop_confirm?: false}

        if question? do
          {:noreply, question_text(state, code)}
        else
          {:noreply, edit(state, {:text, code})}
        end

      {:key, km_event} ->
        # while the decide task is in flight the dialog is hidden and its
        # keys must not fire again (deciding? is false then)
        cond do
          question? -> {:noreply, question_special(state, km_event.key)}
          Map.get(state, :budget_prompt) != nil -> handle_budget_key(km_event, state)
          Map.get(state, :doom_prompt) != nil -> handle_doom_key(km_event, state)
          deciding? -> handle_decision_key(km_event, state)
          true -> handle_input_key(km_event, ev, state)
        end
    end
  end

  # The question wizard owns raw key/text handling: digits toggle an
  # option, enter confirms, esc cancels (asks "unanswered" for the rest),
  # printable text is a custom answer buffer. A one-question screen at a
  # time (ADR 027 open question 1).
  #
  # Special keys (atoms) and text (strings) arrive on separate paths:
  # `question_special/2` for keymap events, `question_text/2` for text.
  defp question_special(%{question_prompt: nil} = state, _key), do: state

  defp question_special(state, key) do
    case key do
      :enter -> question_confirm(state)
      :esc -> question_cancel(state)
      :backspace -> question_backspace(state)
      :arrow_up -> question_move(state, -1)
      :arrow_down -> question_move(state, +1)
      :arrow_left -> question_move(state, -1)
      :arrow_right -> question_move(state, +1)
      _ -> state
    end
  end

  defp question_text(%{question_prompt: nil} = state, _text), do: state

  defp question_text(state, text) do
    # A digit toggles an option ONLY while no custom answer is being
    # typed: inside the free-text buffer a digit is text like any other
    # ("0 is free text" must not make every number untypeable — found
    # live: an answer of "42" selected option 4 and wiped the buffer).
    case {state.question_prompt.custom, text} do
      {nil, d} when d in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"] ->
        question_toggle(state, d)

      _ ->
        question_type(state, text)
    end
  end

  # Toggle the option at a 1-based digit (0 = the "type your own" row).
  # Every activation is EXCLUSIVE: choosing "type your own" drops the
  # selection the same way a typed character does (an edit gesture means
  # the option is no longer the answer), and choosing an option drops any
  # custom buffer — otherwise both rows paint their marker at once and
  # `question_confirm/1`'s ordering silently decides which one wins.
  defp question_toggle(state, digit) do
    qp = state.question_prompt
    question = Enum.at(qp.questions, qp.index)
    options = question["options"] || []
    n = length(options)
    idx = String.to_integer(digit)

    cond do
      # "0" starts a custom answer (the always-present free-text row)
      idx == 0 ->
        %{state | question_prompt: %{qp | custom: "", selected: []}}

      idx >= 1 and idx <= n ->
        multiple? = question["multiple"] || false
        j = idx - 1

        selected =
          if multiple? do
            if j in qp.selected, do: qp.selected -- [j], else: qp.selected ++ [j]
          else
            [j]
          end

        %{state | question_prompt: %{qp | selected: selected, custom: nil}}

      true ->
        state
    end
  end

  defp question_type(state, text) do
    qp = state.question_prompt

    # typing always starts (or continues) a custom answer; typing over a
    # selected option clears the selection — the typed text IS the answer
    # then (found live: the no-op while an option was selected felt like
    # a dead keyboard, with no visible way back to the custom row).
    cond do
      qp.custom != nil -> %{state | question_prompt: %{qp | custom: qp.custom <> text}}
      true -> %{state | question_prompt: %{qp | custom: text, selected: []}}
    end
  end

  defp question_backspace(state) do
    qp = state.question_prompt

    # backspace over a selected option drops the selection and opens an
    # empty custom buffer (same rule as typing: an edit gesture means the
    # option is no longer the answer)
    case qp.custom do
      nil when qp.selected != [] ->
        %{state | question_prompt: %{qp | custom: "", selected: []}}

      nil ->
        state

      "" ->
        %{state | question_prompt: %{qp | custom: nil}}

      buf ->
        # GRAPHEME-wise, not byte-wise: `byte_size/1` made backspace a
        # no-op on multibyte text ("abä": byte_size 4 -> slice(…, 3)
        # returns "abä" unchanged; found live with German input)
        %{state | question_prompt: %{qp | custom: String.slice(buf, 0..-2//1)}}
    end
  end

  defp question_move(state, _dir) do
    # single-question screens: movement is a no-op placeholder for a
    # future form layout (ADR 027 open question 1)
    state
  end

  # Confirm the current question: record its answer and advance, or finish
  # and send all answers when it was the last.
  defp question_confirm(state) do
    qp = state.question_prompt
    question = Enum.at(qp.questions, qp.index)
    options = question["options"] || []

    labels =
      cond do
        qp.custom != nil and qp.custom != "" -> [qp.custom]
        qp.selected != [] -> Enum.map(qp.selected, fn j -> label_of(Enum.at(options, j)) end)
        true -> []
      end

    answers = qp.answers ++ [labels]
    next = qp.index + 1

    if next >= length(qp.questions) do
      question_send(%{state | question_prompt: nil}, answers)
    else
      %{state | question_prompt: %{qp | index: next, selected: [], answers: answers, custom: nil}}
    end
  end

  # Esc: answer the current and all remaining questions as unanswered, and
  # send (the model sees "Unanswered" and proceeds).
  defp question_cancel(state) do
    qp = state.question_prompt
    remaining = length(qp.questions) - qp.index
    answers = qp.answers ++ List.duplicate([], remaining)
    question_send(%{state | question_prompt: nil}, answers)
  end

  defp question_send(state, answers) do
    sid = state.session_id
    parent = self()

    Task.start(fn ->
      result =
        case Session.answer_question(sid, answers) do
          {:ok, session_state} -> {:ok, session_state.status}
          {:error, reason} -> {:error, reason}
        end

      send(parent, {:__question_answered__, result})
    end)

    %{state | status: :running}
  end

  defp label_of(nil), do: ""
  defp label_of(o), do: o["label"] || o[:label] || ""

  # At the budget prompt: y continues (another full budget), n stops
  # (wrap up). Run the reply in a Task — budget_decision/2 is a call that
  # runs the rest of the turn (a provider round-trip) and must not block
  # the render loop, exactly like decide/2.
  defp handle_budget_key(km_event, state) do
    case Keymap.resolve(decision_keymap(), km_event) do
      :approve -> {:noreply, budget_decide(state, :continue)}
      :reject -> {:noreply, budget_decide(state, :stop)}
      _ -> {:noreply, state}
    end
  end

  defp budget_decide(state, decision) do
    sid = state.session_id
    parent = self()

    Task.start(fn ->
      result =
        case Session.budget_decision(sid, decision) do
          {:ok, session_state} -> {:ok, session_state.status}
          {:error, reason} -> {:error, reason}
        end

      send(parent, {:__budget_decided__, result})
    end)

    # Optimistic: hide the prompt now, resume running; the reply
    # reconciles (or re-opens on a refusal)
    %{state | budget_prompt: nil, status: :running}
  end

  # At the doom-loop prompt: y continues the repeated round anyway, n
  # rejects it (the held round is answered with steering so the model
  # changes approach).
  defp handle_doom_key(km_event, state) do
    case Keymap.resolve(decision_keymap(), km_event) do
      :approve -> {:noreply, doom_decide(state, :continue)}
      :reject -> {:noreply, doom_decide(state, :reject)}
      _ -> {:noreply, state}
    end
  end

  defp doom_decide(state, decision) do
    sid = state.session_id
    parent = self()

    Task.start(fn ->
      result =
        case Session.doom_decision(sid, decision) do
          {:ok, session_state} -> {:ok, session_state.status}
          {:error, reason} -> {:error, reason}
        end

      send(parent, {:__doom_decided__, result})
    end)

    %{state | doom_prompt: nil, status: :running}
  end

  # Menu popup overlay (the pending note is on the composer's meta
  # row, popup is
  # a Clear-backed list box — same pattern as the picker).
  defp menu_widgets(%{menu_popup: nil}, _area), do: []

  defp menu_widgets(state, area) do
    items = state.menu_popup.items

    # The popup must stay ABOVE the live band, so a list longer than the
    # room has to become a WINDOW around the selection: truncating it
    # would silently drop rows (the keymap list is 21 entries, the room
    # 20 rows at 100x30) and the selection marker would walk off the
    # bottom. The marker keeps the ABSOLUTE index, so navigation is
    # unchanged — only what is painted moves.
    room = overlay_room(state, area)
    visible = max(room - 3, 1)
    offset = window_offset(state.menu_index, length(items), visible)
    window = Enum.slice(items, offset, visible)

    rows =
      window
      |> Enum.with_index(offset)
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

    body =
      ([" " <> popup_title(state.menu_popup, offset, length(window), length(items))] ++ rows)
      |> Enum.join("\n")

    # the popup and the band may not overlap, and the popup can be taller
    # than the room above it: `overlay_rect/4` clamps it (a menu taller
    # than the pane used to be placed at a negative row)
    w = min(60, area.width - 4)
    rect = overlay_rect(state, area, length(rows) + 3, w)

    widget = %Paragraph{
      text: body,
      style: Styles.surface(:chrome),
      block:
        Styles.panel(
          title: " menu ",
          surface: :chrome,
          border_style: Styles.role(:accent, :chrome)
        )
    }

    [{%Clear{}, rect}, {widget, rect}]
  end

  # The window's first item: it follows the selection only when the
  # selection would leave it, so a short list never scrolls and a long one
  # behaves like a viewport (the same tail-anchored-in-reverse idea as the
  # transcript, one dimension down).
  defp window_offset(index, total, visible) do
    max(min(index - div(visible, 2), total - visible), 0)
  end

  # The title, with the position when the list is longer than the window:
  # a windowed list that does not say it is one is a lie of omission (the
  # "17 of 21" is the honest form of the truncation this replaces).
  defp popup_title(popup, offset, shown, total) do
    base = popup.title

    if shown < total do
      "#{base}  (#{offset + 1}-#{offset + shown}/#{total})"
    else
      base
    end
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
  # transient note in the composer's meta row (menu prompts); cleared on the
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

  # Subagent tab picker (ADR 018): one row per child of THIS view plus a
  # "primary" row back to the parent transcript. Finished children are
  # listed after the active ones (the owner keeps every subagent of a
  # session). Items carry {:tab, child_id | nil} as `id`.
  defp subagents_popup(state) do
    subs = Map.get(state, :subagents, %{})

    if map_size(subs) == 0 do
      {:noreply, status_note(%{state | menu_pending: false}, "no subagents in this session")}
    else
      primary = %{
        id: {:tab, nil},
        label: "primary transcript",
        status: nil,
        action: :open_tab
      }

      children =
        subs
        |> Enum.sort_by(fn {_id, c} -> {Map.get(c, :finished?, false), Map.get(c, :agent)} end)
        |> Enum.map(fn {id, c} ->
          state_mark =
            cond do
              id == active_tab_id(state) -> " (viewing)"
              Map.get(c, :finished?, false) -> " (finished)"
              true -> " (running)"
            end

          %{
            id: {:tab, id},
            label: "#{Map.get(c, :agent)} · #{Map.get(c, :model)}#{state_mark}",
            status: nil,
            action: :open_tab
          }
        end)

      {:noreply,
       %{
         state
         | menu_popup: %{
             id: :subagents,
             title: " subagents  (arrows, enter=open, esc=cancel)",
             items: [primary | children]
           },
           menu_popup_id: :subagents,
           menu_pending: false,
           menu_index: 0
       }}
    end
  end

  # Selection from the subagents popup: swap the transcript pane to the
  # chosen tab (nil = parent). The parent's own scroll/open state is
  # untouched — each tab keeps its own.
  defp open_subagent_tab(%{id: {:tab, tab}}, state) do
    {:noreply, %{state | active_tab: tab, scroll_offset: Map.get(state, :scroll_offset, 0)}}
  end

  defp open_subagent_tab(_other, state), do: {:noreply, state}

  # model switch popup: one item per candidate model. Items are plain
  # maps ({id, source}) — the selection handler switches the session.
  # `current` is marked so the owner sees where they are.
  defp model_popup(state) do
    {:ok, %{entries: entries, note: note}} =
      Discovery.all_models_cached(provider_config_of(state))

    items =
      Enum.map(entries, fn %{id: id, source: source} ->
        mark = if state.model == id, do: " (current)", else: ""

        %{
          id: id,
          label: id <> mark <> if(source == :discovered, do: "  (live)", else: ""),
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
            %{id: m, label: m <> " (current)", status: nil, action: :model_selected}
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

    # Open with the cursor ON the running model (found live: landing on
    # index 0 — the alphabetically first discovered id, e.g.
    # "deepseek-v4-flash:0731" — made that row look like the current
    # model, which is exactly the wrong reading).
    index = Enum.find_index(items, &(&1.id == state.model)) || 0

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
         menu_index: index
     }}
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
    # ctrl-x: enter pending mode; the timer turns it into the popup.
    # CANCEL any earlier timer first: a timer from a previous ctrl-x whose
    # prefix was consumed (or whose popup was dismissed) must not fire
    # during THIS window and steal it.
    cancel_menu_timer(state)

    ref = Process.send_after(self(), :__menu_timeout__, @menu_timeout)

    state =
      %{state | menu_pending: true, menu_timer: ref}
      |> status_note("menu: press a letter… (or wait for the list)")

    {:noreply, state}
  end

  defp handle_menu_or_normal_key(ev, %{menu_pending: true} = state) do
    # any key while pending: consume the prefix and CANCEL its timer, so
    # the popup cannot appear a moment later on top of the handled key.
    state = cancel_menu_timer(state)

    case Menu.resolve(Menu.main_menu(), ev.code) do
      nil ->
        {:noreply, %{state | menu_pending: false}}

      item ->
        # clear the "press a letter…" note so the meta row returns to
        # its normal content (else the note masks the debug line, etc.)
        state = %{state | menu_pending: false, menu_note: nil}

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

  # Cancel the armed menu timer, if any, and forget the ref.
  defp cancel_menu_timer(%{menu_timer: ref} = state) when ref != nil do
    Process.cancel_timer(ref)
    %{state | menu_timer: nil}
  end

  defp cancel_menu_timer(state), do: %{state | menu_timer: nil}

  # timer fired: the owner waited -> show the popup instead of the
  # fast path (id nil: the MAIN menu, whose items carry actions)
  defp open_menu_popup(popup, state) do
    # the popup's own id distinguishes target-picking popups
    # (switch_session) from plain menus (the main menu: nil)
    id = if Map.get(popup, :id) == :main, do: nil, else: Map.get(popup, :id)

    %{
      state
      | menu_popup: popup,
        menu_popup_id: id,
        menu_index: 0,
        menu_pending: false,
        menu_timer: nil
    }
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
      :subagents -> open_subagent_tab(selected, state)
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

  # Subagent tabs (ADR 018): open the tab of a child in this session, or
  # the parent transcript. An empty list (no delegation yet) is a note.
  defp run_menu_action(:subagents, state), do: subagents_popup(state)

  # model switch: catalog (req_llm) + discovered (GET, dialect per
  # provider entry) candidates, cached per mount. Never blocks the TUI
  # longer than the discovery timeout; a dead server = a note, and the
  # popup still opens (with whatever resolved).
  defp run_menu_action(:switch_model, state), do: model_popup(state)

  defp run_menu_action(:toggle_tool_output, state) do
    {:noreply, toggle_last_tool(state)}
  end

  defp run_menu_action(:toggle_sidebar, state), do: {:noreply, toggle_sidebar(state)}

  defp run_menu_action(:toggle_debug, state),
    do: {:noreply, %{state | debug_visible?: not Map.get(state, :debug_visible?, false)}}

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

  # Actions the TUI drives itself (the complement is the editing actions,
  # owned by UI.Editor). The coverage tripwire asserts the two sets
  # partition every declared keymap action, so a new action cannot fall
  # through unowned.
  @doc false
  def handled_input_actions do
    [
      :toggle_tool_output,
      :switch_agent,
      :scroll_up,
      :scroll_down,
      :send_input,
      :history_prev,
      :history_next,
      :interrupt,
      :abort
    ]
  end

  defp dispatch_input_key(km_event, _ev, state) do
    case Keymap.resolve(state.keymap, km_event) do
      :toggle_tool_output ->
        state = toggle_last_tool(state)
        state = clamp_scroll_now(state)
        {:noreply, state}

      :switch_agent ->
        {:noreply, switch_agent(state)}

      :scroll_up ->
        # clamp at the top: an offset past the max inflates silently
        # (the screen stops updating but the number keeps growing) and
        # that stale value then makes scroll-down feel dead (found live).
        # With lazy measurement (ADR 028) the clamp IS the walk — the
        # viewport discovers the top and returns the accepted offset.
        {:noreply, scroll_active(state, +5) |> clamp_scroll_now()}

      :scroll_down ->
        {:noreply, scroll_active(state, -5)}

      :send_input ->
        {:noreply, send_input(state)}

      :history_prev ->
        {:noreply, history_step(state, +1)}

      :history_next ->
        {:noreply, history_step(state, -1)}

      # esc while a turn is in flight (running OR already stopping):
      # DOUBLE press to stop. A lone esc must never stop — esc is
      # pressed out of habit in text fields (vim muscle memory: "I
      # sometimes press esc out of habit"). First esc arms and shows a
      # hint; a second esc within @stop_confirm_window actually stops
      # (idempotent, and it must NEVER arm the quit confirm — the old
      # cascade was found live: esc #1 set :interrupting, esc #2 fell
      # through and ARMED quit, esc #3 killed the app). Esc-to-quit is
      # only reachable while idle; to quit a busy app use ctrl-c.
      :interrupt ->
        if state.status in [:running, :interrupting] do
          esc_stop(state)
        else
          interrupt_idle(state)
        end

      :abort ->
        {:stop, state}

      action ->
        cond do
          # The one executor (ADR 021): editing actions are performed by
          # UI.Editor from the action NAME — the raw event never reaches
          # the crate, so the keymap and the crate cannot disagree.
          Editor.editing_action?(action) ->
            {:noreply, edit(state, action)}

          # :unbound or an action with no owner: drop it. This is the
          # boundary that used to forward the raw event to the crate —
          # the second authority ADR 021 removes. Any key also disarms
          # the esc confirm (only esc drives them).
          true ->
            {:noreply, %{state | quit_confirm?: false, stop_confirm?: false}}
        end
    end
  end

  # esc while busy, double-press to stop. First esc arms (status stays
  # put; the composer's meta row shows the hint), second esc within the window
  # requests the stop. A stale arm counts as a fresh first press.
  defp esc_stop(state) do
    armed? =
      state.stop_confirm? and
        System.monotonic_time(:millisecond) - Map.get(state, :stop_armed_at, 0) <=
          @stop_confirm_window

    if armed? do
      Session.interrupt(state.session_id)
      # A running `task` child blocks the parent's turn worker inside the
      # `task` call, so the parent's stop only lands between tool calls —
      # after the child. Forward the stop to every ACTIVE child (its own
      # interrupt id) so a long delegation is cancellable (ADR 018).
      for {id, child} <- Map.get(state, :subagents, %{}), not Map.get(child, :finished?, false) do
        Session.interrupt(id)
      end

      {:noreply,
       %{
         state
         | status: :interrupting,
           stop_confirm?: false,
           quit_confirm?: false,
           transcript: state.transcript ++ [{:info, "interrupting…"}]
       }}
    else
      now = System.monotonic_time(:millisecond)
      {:noreply, %{state | stop_confirm?: true, stop_armed_at: now}}
    end
  end

  # Idle esc-to-quit: esc #1 arms, esc #2 within the window quits,
  # anything else disarms. Esc-to-quit must never fire on the first
  # press — the user types esc reflexively (found live:
  # "ESC -> ARE YOU SURE -> ESC -> BREAK").
  defp interrupt_idle(state) do
    if state.quit_confirm? and
         System.monotonic_time(:millisecond) - Map.get(state, :quit_armed_at, 0) <=
           @quit_confirm_window do
      {:stop, %{state | quit_confirm?: false}}
    else
      # stale arms count as fresh — the user sees the "esc again to
      # quit" hint and presses again
      now = System.monotonic_time(:millisecond)
      {:noreply, %{state | quit_confirm?: true, quit_armed_at: now}}
    end
  end

  defp send_input(state) do
    value = String.trim(ExRatatui.textarea_get_value(state.textarea))

    if value == "" do
      state
    else
      # attribute THIS turn to the agent the input was prepared for: the
      # `next` slot. It stays in sync with what Session.run resolves
      # (the next_agent at send time), so the composer's identity footer
      # is correct even while a prior turn streams.
      next_agent = Map.get(state, :next_agent)

      run_prompt(state, value)

      %{
        state
        | textarea: ExRatatui.textarea_new(),
          history: [value | state.history],
          history_index: nil,
          transcript: state.transcript ++ [{:user, value}],
          status: :running,
          # a fresh turn: no stale esc arm or stream from the previous one
          stop_confirm?: false,
          stream: [],
          stream_dirty?: false,
          # start the silence clock now (see handle_info {:__run__, ...})
          last_activity_at: now_ms(),
          active_tool: nil,
          tool_started_at: nil,
          scroll_offset: 0,
          turn_agents: Map.get(state, :turn_agents, []) ++ [next_agent]
      }
    end
  end

  # Tests are LLM-free: a test-mode TUI must never reach the provider.
  # The TUI's own test_mode only skipped the picker and the startup
  # probe — an alt-enter still spawned Session.run and dialed the real
  # provider (the econnrefused retry storm in the suite output). Guard
  # the one place the TUI starts a turn.
  defp run_prompt(%{test_mode?: true} = state, _prompt), do: state

  defp run_prompt(state, prompt) do
    Task.start(fn -> Session.run(state.session_id, prompt) end)
    state
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

    # Optimistic UI: HIDE the dialog now (deciding?), but KEEP `pending`
    # until the reply. If decide/2 errors (e.g. {:not_interrupted, :idle}
    # from a race), the dialog can re-appear instead of losing the user's
    # answer with the calls still parked on the session.
    %{state | deciding?: true, pending_edit: nil, status: :running}
  end

  # Apply ONE edit through the single executor (ADR 021). The raw
  # terminal event never reaches the crate; the intent is an action name
  # or a text string. Then re-derive the pane: an edit can grow the input
  # box (opencode-style), which changes the transcript pane height
  # (measure/render agreement, as the resize handler does).
  defp edit(state, intent) do
    :ok = Editor.apply(state.textarea, intent)
    rederive_pane(state)
  end

  defp rederive_pane(state) do
    case pane_size(state) do
      {w, h} ->
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
    # The decisions landed. The parked calls are gone UNLESS the turn
    # paused again (status :interrupted) — in that case a fresh
    # status_changed broadcast carries the new pending list, so keep it
    # and just clear the deciding guard.
    pending = if status == :interrupted, do: state.pending, else: []
    {:noreply, %{state | status: status, pending: pending, deciding?: false}}
  end

  # The budget reply landed (ADR 025). The session's broadcasts are
  # authoritative and have already moved the UI (`:running` cleared the
  # prompt; a fresh `:budget_reached` may have opened the NEXT one), so
  # the reply is a NO-OP — it carries nothing the broadcasts did not:
  # touching the prompt here used to close a fresh dialog when the reply
  # arrived late (the question-wizard race, ADR 027 amendment; the same
  # class hit all three reply handlers).
  def handle_info({:__budget_decided__, {:ok, _status}}, state) do
    {:noreply, state}
  end

  # A refusal (the pause was already resolved, a race): re-read the
  # session and re-open the prompt when a pause is still parked instead
  # of dropping the dialog silently.
  def handle_info({:__budget_decided__, {:error, reason}}, state) do
    state = note_failure(resync_prompt(state, :budget), "budget answer failed", reason)
    {:noreply, state}
  end

  # The doom-loop reply landed (ADR 026): a no-op, like the budget reply.
  def handle_info({:__doom_decided__, {:ok, _status}}, state) do
    {:noreply, state}
  end

  def handle_info({:__doom_decided__, {:error, reason}}, state) do
    state = note_failure(resync_prompt(state, :doom), "doom answer failed", reason)
    {:noreply, state}
  end

  # The question answer landed (ADR 027): a no-op, like the budget reply.
  # The reported live bug: answering Q1, the session asks Q2 (its
  # `:question_asked` broadcast opens the wizard) and only THEN does the
  # answer worker finish — the late reply used to clear the fresh Q2
  # dialog ("the dialog disappears, the band says approval needed").
  def handle_info({:__question_answered__, {:ok, _status}}, state) do
    {:noreply, state}
  end

  def handle_info({:__question_answered__, {:error, reason}}, state) do
    state = note_failure(resync_prompt(state, :question), "answer failed", reason)
    {:noreply, state}
  end

  # the session is no longer waiting (its parked calls resolved or were
  # dropped elsewhere): the dialog is stale, clear it
  def handle_info({:__decided__, {:error, {:not_interrupted, status}}}, state) do
    {:noreply, %{state | pending: [], deciding?: false, status: status}}
  end

  def handle_info({:__decided__, {:error, reason}}, state) do
    # any other refusal (e.g. missing decisions): the session may still
    # hold the calls, so RE-OPEN the dialog with a visible note instead
    # of silently losing the user's y/n — `pending` was never dropped
    {:noreply,
     %{
       state
       | last_error: reason,
         deciding?: false,
         stop_confirm?: false,
         status: :interrupted,
         transcript: state.transcript ++ [{:info, "✖ decision failed: #{error_text(reason)}"}]
     }}
  end

  # Events arrive TAGGED with their source session id (ADR 018). The TUI
  # subscribes to the parent AND to each running child; the tag routes a
  # child's events into its own tab buffer and NEVER into the parent
  # transcript (the part-3 invariant: visibility is not context). A parent
  # event forwards to the 2-tuple clauses below unchanged; an unknown
  # source is dropped rather than blended anywhere.
  def handle_info({:agent, id, event}, %{session_id: id} = state) do
    handle_info({:agent, event}, state)
  end

  # A child's delta defers its render exactly like the parent's (F2):
  # marking the dirty flag and returning `render?: false` means one
  # throttle frame per @stream_render_ms instead of a full paint per
  # delta. The child path used to fall through to the default
  # `render?: true`, so a delegating parent painted every child delta —
  # O(n²) with the growing stream buffer. The tick is armed by
  # `subscriptions/1` (which looks at child streams too, not just the
  # parent's).
  def handle_info({:agent, child_id, {kind, _delta} = event}, %{subagents: subs} = state)
      when is_map_key(subs, child_id) and kind in [:llm_deltas, :reasoning_deltas] do
    state =
      state
      |> accumulate_child(child_id, event)
      |> Map.put(:stream_dirty?, true)

    {:noreply, state, %{render?: false}}
  end

  def handle_info({:agent, child_id, event}, %{subagents: subs} = state)
      when is_map_key(subs, child_id) do
    {:noreply, accumulate_child(state, child_id, event)}
  end

  def handle_info({:agent, _id, _event}, state), do: {:noreply, state}

  # Streaming deltas DEFER their render: fold the delta and return
  # `render?: false`, so the server processes the next message instead of
  # painting the growing markdown transcript per delta. A subscription
  # (subscriptions/1) ticks every @stream_render_ms while a stream is
  # live and is the ONLY thing that paints it.
  #
  # Found live: a long reasoning stream emits hundreds of tiny deltas;
  # rendering per delta buried typed keys and ESC behind a render train
  # (a 500-delta burst blocked `:sys.get_state` past 5s). The earlier
  # `drain_deltas` fix peeked the mailbox with `receive … after 0`, which
  # STILL starved input on a steady trickle (the `after 0` rarely fires
  # when deltas keep arriving). Deferring the render removes the mailbox
  # peek entirely: input is handled in the normal loop, and one frame per
  # window keeps the stream visibly live.
  def handle_info({:agent, {:llm_deltas, delta}}, state) do
    state =
      state
      |> touch()
      |> Map.put(:stream_dirty?, true)
      |> Map.update!(:stream, &append_stream(&1, :assistant, delta))

    {:noreply, state, %{render?: false}}
  end

  def handle_info({:agent, {:status_changed, status}}, state) do
    # every status broadcast means the turn moved on: a pending esc-stop
    # arm is stale once the agent is no longer busy
    state =
      if status in [:idle, :error, :interrupted], do: %{state | stop_confirm?: false}, else: state

    # a tool "in flight" cannot survive the turn that started it: the
    # result that would clear it is never coming (a crashed turn, a
    # pause). Without this the next :running after a decide would flash
    # "running mix" for a call that already ended.
    state = if status in [:idle, :error, :interrupted], do: end_tool(state), else: state

    # an authoritative move OFF :interrupted means the parked calls are
    # resolved or gone: clear the dialog and the deciding guard (a
    # refused decide/2 can race a status broadcast)
    state =
      if status != :interrupted do
        %{
          state
          | pending: [],
            deciding?: false,
            budget_prompt: nil,
            doom_prompt: nil,
            question_prompt: nil
        }
      else
        state
      end

    {:noreply, %{state | status: status}}
  end

  # The session parked at the tool-round budget (ADR 025): show the
  # continue/stop prompt. Distinct from the approval dialog — no pending
  # TOOL calls, so the two never collide (and a stale approval `pending`
  # from a decide still in flight is dropped: it belongs to a pause that
  # is over).
  def handle_info({:agent, {:status_changed, :budget_reached, %{budget: budget}}}, state) do
    {:noreply,
     %{
       state
       | status: :interrupted,
         budget_prompt: %{budget: budget},
         pending: [],
         deciding?: false,
         stop_confirm?: false
     }}
  end

  # The session parked at a detected doom loop (ADR 026): show the
  # continue/reject prompt (a stale approval `pending` is dropped, as for
  # the budget).
  def handle_info({:agent, {:status_changed, :doom_reached, %{tool: tool}}}, state) do
    {:noreply,
     %{
       state
       | status: :interrupted,
         doom_prompt: %{tool: tool},
         pending: [],
         deciding?: false,
         stop_confirm?: false
     }}
  end

  # The session parked on a question the model asked (ADR 027): show the
  # wizard. The question text is what the agent wants to know. A stale
  # approval `pending` is dropped: a question pause has no pending tool
  # calls, and leaving the list would paint the approval dialog OVER the
  # wizard when the decide reply lands after this broadcast.
  def handle_info({:agent, {:status_changed, :question_asked, %{questions: questions}}}, state) do
    {:noreply,
     %{
       state
       | status: :interrupted,
         question_prompt: %{
           questions: questions,
           index: 0,
           selected: [],
           answers: [],
           custom: nil
         },
         pending: [],
         deciding?: false,
         stop_confirm?: false
     }}
  end

  # :interrupted carries the pending calls as detail — this is how the
  # TUI learns WHAT to render in the approval dialog (a live interrupt
  # during a run; attaching mid-session pulls state on mount instead).
  def handle_info({:agent, {:status_changed, :interrupted, pending}}, state) do
    {:noreply,
     %{
       end_tool(state)
       | status: :interrupted,
         pending: pending,
         stop_confirm?: false
     }}
  end

  def handle_info({:agent, {:status_changed, :error, reason}}, state) do
    # A failed turn becomes a visible transcript line, not a raw logger
    # dump over the alternate screen. Partial streamed output is flushed
    # first so it is not lost when the error line lands, then the buffer
    # clears.
    #
    # The hint is CLASSIFIED, not blanket: a build/encoding failure is
    # local (our bug) and says so, while a transport/auth failure names
    # the provider. The old blanket "check the provider (ollama up?)"
    # misled a real debugging session — a poisoned context read as
    # "provider down" and sent the user chasing ollama.
    {kind, hint} = classify_failure(reason)

    msg =
      case kind do
        :provider -> "✖ provider failed: #{error_text(reason)} — #{hint}"
        :local -> "✖ turn failed (not the provider): #{error_text(reason)} — #{hint}"
        :other -> "✖ turn failed: #{error_text(reason)} — #{hint}"
      end

    transcript = state.transcript ++ persist_stream(state.stream, nil) ++ [{:info, msg}]

    {:noreply,
     %{
       end_tool(state)
       | status: :error,
         stop_confirm?: false,
         transcript: transcript,
         stream: [],
         stream_dirty?: false
     }}
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
    #
    # The in-flight stream is persisted IN ARRIVAL ORDER (opencode
    # parity): each reasoning block stays a dim entry at the position it
    # streamed, so an answer the agent gave BETWEEN thoughts keeps that
    # position instead of collapsing below everything it thought later.
    # `text` is the authoritative full answer; it is used only when no
    # assistant deltas streamed (non-streamed / resumed turns).
    transcript = state.transcript ++ persist_stream(state.stream, text)
    {:noreply, %{state | transcript: transcript, stream: [], stream_dirty?: false}}
  end

  # Agent thinking: a dim block that interleaves with the answer text in
  # the order the provider streamed them (see append_stream/3). The
  # buffer is kept VERBATIM (markdown; CommonMark collapses blank runs),
  # and the display shape trims trailing newlines so the box never grows
  # a phantom row (see render_reasoning/1). The delta DEFERS its render:
  # the stream throttle (subscriptions/1) paints it on a fixed cadence.
  def handle_info({:agent, {:reasoning_deltas, delta}}, state) do
    state =
      state
      |> touch()
      |> Map.put(:stream_dirty?, true)
      |> Map.update!(:stream, &append_stream(&1, :reasoning, delta))

    {:noreply, state, %{render?: false}}
  end

  # A tool call is about to run. Tools run synchronously on the worker,
  # so this is the only signal that a tool is *in flight*; the status
  # reads "running mix" until the matching {:tool_executed, ...}.
  def handle_info({:agent, {:tool_started, name}}, state) do
    {:noreply, %{touch(state) | active_tool: name, tool_started_at: now_ms()}}
  end

  # The event carries the call's arguments (4-tuple) so the display view
  # can record them; the live transcript shows the result only, exactly as
  # before. The 3-tuple clause below stays for hand-built/test events.
  def handle_info({:agent, {:tool_executed, name, content, _args}}, state) do
    handle_info({:agent, {:tool_executed, name, content}}, state)
  end

  def handle_info({:agent, {:tool_executed, name, content}}, state) do
    id = "tool-#{System.unique_integer([:positive])}"

    # display shape: capped output (head+tail) — the core session
    # keeps the full output. Reasoning/answer streamed ahead of the tool
    # call persists too (same rule as llm_message).
    content = cap_lines(content, @tool_cap)

    transcript =
      state.transcript ++ persist_stream(state.stream, nil) ++ [{:tool, id, name, content}]

    state =
      state
      |> touch()
      |> Map.put(:transcript, transcript)
      |> Map.put(:stream, [])
      |> Map.put(:stream_dirty?, false)
      # clear the in-flight tool when its result lands (a round can have
      # several calls; the next {:tool_started} re-sets it)
      |> clear_tool_if_done(name)

    {:noreply, state}
  end

  def handle_info({:agent, {:context_compacted, _keep}}, state) do
    {:noreply, %{state | transcript: state.transcript ++ [{:info, "· context compacted"}]}}
  end

  # A `task` call started a child session (ADR 017/018). The child's own
  # events arrive on the child's channel; the parent event just tells the
  # UI a delegation is live, so the live band and sidebar can name the
  # LEAF. Its transcript is never blended into the parent view.
  # A `task` call started a child session (ADR 017/018): subscribe to the
  # child's channel so its stream reaches the tab buffer (the parent
  # channel carries only the start/finish events). The tab is kept after
  # the child finishes (the owner keeps every subagent of a session); the
  # band names the LEAF while it runs.
  def handle_info({:agent, {:subagent_started, child_id, agent, model}}, state) do
    state = touch(state)
    sub = child_state(agent, model)

    subscribe_child(child_id)

    state = %{
      state
      | subagents: Map.put(state.subagents, child_id, sub),
        active_subagent: child_id
    }

    # the tab bar appears with the first child: re-derive the pane height
    # so the transcript viewport matches what render/2 will paint (ADR 028)
    {:noreply, rederive_pane(state)}
  end

  def handle_info({:agent, {:subagent_finished, child_id, outcome}}, state) do
    state = touch(state)

    transcript =
      case outcome do
        :error -> state.transcript ++ [{:info, "· subagent ended with an error"}]
        _ -> state.transcript
      end

    # The tab is NOT deleted: it stays readable (finished) until the view
    # is discarded (session switch). Unsubscribe — the child is stopped,
    # so no further events will come; the registration would otherwise
    # outlive the process as a dead entry.
    Registry.unregister(CodingAgent.EventRegistry, {CodingAgent.Core.Events.key(), child_id})

    subagents =
      case Map.fetch(state.subagents, child_id) do
        {:ok, child} -> Map.put(state.subagents, child_id, %{child | finished?: true})
        :error -> state.subagents
      end

    {:noreply,
     %{
       state
       | subagents: subagents,
         active_subagent:
           if(state.active_subagent == child_id, do: nil, else: state.active_subagent),
         transcript: transcript
     }}
  end

  def handle_info({:agent, {:turn_started, agent}}, state) do
    # the session resolved the agent this turn is running as; refresh the
    # live attribution used by streaming lines and the live band.
    # Starting the silence clock here means a turn that produces no delta
    # for a while still reads "thinking · Ns".
    #
    # The MODEL comes from the SESSION's own resolution
    # (`State.effective_model/1`, the same function `wire_request/2`
    # uses) — not from a fresh disk read or the cached value. The cache
    # names the PREVIOUS turn's agent (a mid-turn Tab leaves it pointing
    # at the old agent while the next turn runs as the new one), and a
    # disk re-read can diverge from the definition the session actually
    # resolved. Asking the session answers "what is really on the wire".
    state = touch(state)

    model = session_effective_model(state.session_id) || Map.get(state, :model)

    {:noreply, %{state | active_agent: agent, running_agent: agent, running_agent_model: model}}
  end

  def handle_info({:__run__, prompt}, state) do
    run_prompt(state, prompt)

    next_agent = Map.get(state, :next_agent)

    {:noreply,
     %{
       state
       | status: :running,
         transcript: state.transcript ++ [{:user, prompt}],
         stream: [],
         stream_dirty?: false,
         # start the silence clock at send: the spinner reads "thinking · Ns"
         # measured from here until the first delta/tool arrives.
         last_activity_at: now_ms(),
         active_tool: nil,
         tool_started_at: nil,
         turn_agents: Map.get(state, :turn_agents, []) ++ [next_agent]
     }}
  end

  # Terminal resize: the local transport dispatches no Resize events,
  # so poll the size (cheap ioctl) and act on changes.
  def handle_info(:__menu_timeout__, %{menu_pending: true} = state) do
    # the owner waited: show the popup instead of the fast path
    {:noreply, open_menu_popup(Menu.main_menu(), %{state | menu_pending: false})}
  end

  def handle_info(:__menu_timeout__, state) do
    # pending was consumed by a key that raced the timer — nothing to do
    # (the ref is spent; drop it so a later cancel is a no-op)
    {:noreply, %{state | menu_timer: nil}}
  end

  def handle_info(:__resize_poll__, state) do
    # re-arm only in production: under test_mode the poll is driven
    # explicitly (the host tty is not the virtual test terminal)
    unless state.test_mode? do
      Process.send_after(self(), :__resize_poll__, 500)
    end

    case pane_size(state) do
      {w, h} ->
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

  # The throttle that paints a live stream. Deltas only mark the buffer
  # dirty and defer (`render?: false`); this tick is the single render
  # source. It clears the dirty flag, which cancels the subscription
  # (subscriptions/1) until the next delta arrives — at most one frame per
  # @stream_render_ms, and none while the stream is quiet.
  def handle_info(@stream_render_tick, state) do
    {:noreply, %{state | stream_dirty?: false}}
  end

  # The spinner tick: advance the frame. The subscription is declared
  # only while a turn is busy (subscriptions/1), so it stops on its own
  # when the turn ends — no manual cancel. Re-rendering here is what makes
  # a silent agent visibly alive.
  def handle_info(@spin_tick, state) do
    {:noreply, %{state | spin: Map.get(state, :spin, 0) + 1}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Re-read the session after a failed answer/decision and re-open the
  # pause's prompt when it is still parked (the refusal can race a FRESH
  # pause broadcast). Without a parked pause the optimistic close stands
  # — the session's state, not the reply, is the authority. A dead
  # session is no authority either: leave the optimistic close alone
  # instead of crashing the UI on the `:noproc` exit.
  defp resync_prompt(state, kind) do
    session_state =
      try do
        case Session.state(state.session_id) do
          {:ok, session_state} -> session_state
          _ -> nil
        end
      catch
        :exit, _ -> nil
      end

    case session_state do
      nil ->
        state

      session_state ->
        %{open_pause(state, kind, session_state) | status: session_state.status}
    end
  end

  defp open_pause(state, :question, session_state) do
    case question_prompt_of(session_state) do
      nil -> state
      prompt -> %{state | question_prompt: prompt}
    end
  end

  defp open_pause(state, :budget, session_state) do
    case budget_prompt_of(session_state) do
      nil -> state
      prompt -> %{state | budget_prompt: prompt}
    end
  end

  defp open_pause(state, :doom, session_state) do
    case doom_prompt_of(session_state) do
      nil -> state
      prompt -> %{state | doom_prompt: prompt}
    end
  end

  defp note_failure(state, what, reason) do
    transcript = state.transcript ++ [{:info, "✖ #{what}: #{error_text(reason)}"}]
    %{state | transcript: transcript}
  end

  # The stream throttle (only while unrendered text) and the busy spinner
  # (only while a turn is in flight). Both reconcile from state, so each
  # stops on its own.
  #
  # Under test_mode no timer is armed (like :__resize_poll__): tests drive
  # the ticks with `fire/2` so buffer assertions are deterministic instead
  # of racing a wall clock. `spinner/1` is asserted directly for the
  # frame set.
  @impl true
  def subscriptions(%{test_mode?: false} = state) do
    stream =
      if Map.get(state, :stream_dirty?, false) and any_stream?(state) do
        [
          %ExRatatui.Subscription{
            id: :stream_render,
            kind: :interval,
            interval_ms: @stream_render_ms,
            message: @stream_render_tick
          }
        ]
      else
        []
      end

    spinner =
      if Styles.busy?(state.status) do
        [
          %ExRatatui.Subscription{
            id: :spinner,
            kind: :interval,
            interval_ms: @spin_ms,
            message: @spin_tick
          }
        ]
      else
        []
      end

    stream ++ spinner
  end

  def subscriptions(_state), do: []

  # Is there an unpainted stream anywhere — the parent's or a child
  # tab's? A delegating parent's own stream is typically EMPTY while the
  # child streams (the parent blocks in the `task` call), so checking
  # only `state.stream` retired the throttle exactly when the child
  # needed it (F2).
  defp any_stream?(state) do
    match?([_ | _], Map.get(state, :stream)) or
      Enum.any?(Map.get(state, :subagents, %{}), fn {_id, child} ->
        match?([_ | _], Map.get(child, :stream, []))
      end)
  end

  # -- activity tracking -----------------------------------------------------

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Any progress from the session means the turn is alive: reset the
  # silence clock. The in-flight tool label is owned by the
  # {:tool_started}/{:tool_executed} pair, not by progress — clearing it
  # here made the label vanish on the first result of a multi-call round
  # (review F2).
  defp touch(state) do
    %{state | last_activity_at: now_ms()}
  end

  # The tool result names the tool it finishes; only clear the in-flight
  # label if it matches (a round can interleave calls and results).
  defp clear_tool_if_done(%{active_tool: name} = state, name),
    do: %{state | active_tool: nil, tool_started_at: nil}

  defp clear_tool_if_done(state, _name), do: state

  # A turn ended (idle/error/paused) with a tool still marked in flight:
  # its result is never arriving, so drop the label rather than let a
  # later :running flash it again. The clock goes with it (the band only
  # counts while busy, so this is hygiene, not display).
  defp end_tool(state) do
    %{state | active_tool: nil, tool_started_at: nil}
  end

  # Seconds since the turn's last activity, or nil when there has been
  # none yet (so a fast turn never flashes a duration). The sentinel is
  # `nil`, not 0: `System.monotonic_time/1` is negative on Linux, so 0 is
  # a valid timestamp.
  defp silence_s(state) do
    case Map.get(state, :last_activity_at) do
      t when is_integer(t) -> div(now_ms() - t, 1000)
      _ -> nil
    end
  end

  # Test mode reports its declared virtual size; production reads the tty.
  defp pane_size(%{test_mode?: true} = state) do
    case state.mount_opts[:test_mode] do
      {w, h} when is_integer(w) and is_integer(h) -> {w, h}
      _ -> :unknown
    end
  end

  defp pane_size(_state) do
    case ExRatatui.terminal_size() do
      {w, h} when is_integer(w) and is_integer(h) -> {w, h}
      _ -> :unknown
    end
  end

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
    # and between the two regions (opencode-comparison lesson: crammed
    # vs airy is margins + spacing, not line height). The window's bottom
    # row is the composer's own padding now (the bottom status row is
    # gone), and the live band sits between the transcript and the field.
    [main_area] =
      Layout.split(area, :vertical, [{:min, 0}], margin: 1, spacing: 1)

    # sidebar hidden: give the whole width to the transcript instead of
    # painting an empty column (the pane stays usable on narrow panes)
    {sidebar_area, mid_area} =
      if Map.get(state, :sidebar_visible?, true) do
        [sa, ma] = Layout.split(main_area, :horizontal, [{:length, @sidebar_width}, {:min, 0}])
        {sa, ma}
      else
        {nil, main_area}
      end

    in_h = input_height(state)
    band_h = LiveBand.height()

    # input pane width: capped at the reading measure so a wide
    # terminal doesn't stretch the input full width (user feedback)
    [mid_area, _air_area] =
      Layout.split(mid_area, :horizontal, [{:length, min(@measure, mid_area.width)}, {:min, 0}])

    # The subagent tab bar (ADR 018) claims one row above the transcript
    # only while a `task` child exists for this session — the parent-only
    # view keeps its full height when nothing was delegated.
    {tab_area, transcript_full} =
      if map_size(Map.get(state, :subagents, %{})) > 0 do
        [t, rest] = Layout.split(mid_area, :vertical, [{:length, 1}, {:min, 0}])
        {t, rest}
      else
        {nil, mid_area}
      end

    # three stacked regions sharing ONE air row between them: transcript,
    # the live band (what the running turn is doing), the input field
    # (what the next input will use). The air row is what separates them
    # visually — no borders anywhere in this stack.
    [transcript_area, _air1, band_area, _air2, input_area] =
      Layout.split(
        transcript_full,
        :vertical,
        [{:min, 0}, {:length, 1}, {:length, band_h}, {:length, 1}, {:length, in_h}]
      )

    sidebar_widgets =
      if sidebar_area do
        [{sidebar_widget(state), sidebar_area}]
      else
        []
      end

    tab_widgets = if tab_area, do: [{tab_bar(state), tab_area}], else: []

    widgets =
      tab_widgets ++
        transcript_widgets(state, transcript_area) ++
        sidebar_widgets ++
        LiveBand.placements(live_band(state), band_area) ++
        Composer.placements(composer(state), input_area)

    widgets ++
      menu_widgets(state, area) ++
      budget_widgets(state, area) ++
      doom_widgets(state, area) ++
      question_widgets(state, area) ++ dialog_widgets(state, area)
  end

  # Viewport rendering: entries intersecting the pane get placed at
  # pane-relative positions; entries starting above the pane top scroll
  # via the widget's own :scroll (Paragraph/Markdown support it).
  #
  # The entry SOURCE is swappable (ADR 018): the parent transcript by
  # default, or an active subagent child's own transcript when its tab is
  # selected. The placement below is identical for both — the tab reuses
  # the parent render path rather than forking a second one.
  defp transcript_widgets(state, pane) do
    {entries, offset, open_id} = active_transcript(state)
    place_entries(entries, pane, offset, open_id)
  end

  # The transcript an active child tab shows: its own entries and its own
  # scroll/open state, so scrolling a tab never moves the parent and vice
  # versa. Falls back to the parent when no tab is selected.
  defp active_transcript(state) do
    case active_child(state) do
      nil ->
        {display_entries(state), Map.get(state, :scroll_offset, 0), Map.get(state, :open_tool_id)}

      {_id, child} ->
        {child_display_entries(child), Map.get(child, :scroll_offset, 0),
         Map.get(child, :open_tool_id)}
    end
  end

  defp place_entries(entries, pane, offset, open_id) do
    w = content_width(max(pane.width - 2, 10))

    # ADR 028: the viewport measures LAZILY from the tail and returns the
    # clamped offset plus pane-relative positions. No eager total_height
    # here — on a long session that cost seconds per cold frame to
    # produce the same pixels.
    {_clamped, selected} = TranscriptView.viewport(entries, pane.height, offset, w, open_id)

    selected
    |> Enum.flat_map(fn {entry, rel, _h} ->
      entry_widgets(entry, w, open_id)
      |> Enum.map(fn {widget, wh} -> {widget, wh, rel} end)
    end)
    |> Enum.map(fn {widget, h, rel} ->
      # rel is the entry's top row relative to the pane (negative when it
      # starts above it: those leading rows are clipped)
      skipped = max(-rel, 0)
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
  #
  # The clamp is the lazy viewport itself (ADR 028): it measures
  # tail-first and knows the maximum only once the walk reaches the head,
  # returning the accepted offset either way. There is no stored maximum —
  # the accepted offset is the whole answer.
  # Clamp the ACTIVE view's scroll (parent or child tab): collapsing or a
  # resize can shrink the content extent below the offset, and the lazy
  # viewport is the clamp (ADR 028).
  defp clamp_scroll_now(state) do
    {entries, offset, open_id} = active_transcript(state)

    pane_height =
      if is_integer(state.last_pane_height), do: state.last_pane_height, else: 24

    pane_width =
      content_width(if is_integer(state.last_pane_width), do: state.last_pane_width, else: 78)

    {clamped, _selected} =
      TranscriptView.viewport(entries, pane_height, offset, pane_width, open_id)

    put_scroll(state, clamped)
  end

  # -- active-view routing (parent or child tab) ----------------------------
  # Each view owns its own scroll offset and open tool id, so switching
  # tabs never disturbs the parent's position and vice versa.
  #
  # `active_tab` is a POINTER into `subagents`, not an independent
  # selection: a tab id that is no longer a key reads as the parent view.
  # Every consumer goes through `active_child/1`, so the lifetime rule has
  # one implementation (F4); `open_subagent_tab/2` is the only writer.

  defp active_child(state) do
    with id when not is_nil(id) <- Map.get(state, :active_tab),
         {:ok, child} <- Map.fetch(Map.get(state, :subagents, %{}), id) do
      {id, child}
    else
      _ -> nil
    end
  end

  # The effective active tab id: nil when no tab is selected OR when the
  # pointer names a tab that no longer exists (viewers treat it as the
  # parent view — the one lifetime rule, F4).
  defp active_tab_id(state) do
    case active_child(state) do
      nil -> nil
      {id, _child} -> id
    end
  end

  defp scroll_active(state, delta) do
    {_entries, offset, _open} = active_transcript(state)
    put_scroll(state, max(offset + delta, 0))
  end

  defp put_scroll(state, offset) do
    case active_child(state) do
      nil ->
        %{state | scroll_offset: offset}

      {id, child} ->
        %{state | subagents: Map.put(state.subagents, id, %{child | scroll_offset: offset})}
    end
  end

  defp active_open_id(state) do
    case active_child(state) do
      nil -> Map.get(state, :open_tool_id)
      {_id, child} -> Map.get(child, :open_tool_id)
    end
  end

  defp put_open_id(state, open) do
    case active_child(state) do
      nil ->
        %{state | open_tool_id: open}

      {id, child} ->
        %{state | subagents: Map.put(state.subagents, id, %{child | open_tool_id: open})}
    end
  end

  # viewport scrolling happens inside the widget when the entry starts
  # above the pane top (Paragraph/Markdown both support :scroll)
  defp apply_scroll(%Paragraph{} = p, 0), do: p
  defp apply_scroll(%Paragraph{} = p, n), do: %{p | scroll: {n, 0}}
  defp apply_scroll(%Markdown{} = m, 0), do: m
  defp apply_scroll(%Markdown{} = m, n), do: %{m | scroll: {n, 0}}
  defp apply_scroll(w, _n), do: w

  # One widget per entry (v1): heights are single-widget, computed via
  # TranscriptView.height. The user AND assistant messages share the
  # same bordered frame (TranscriptView.agent_block — one definition
  # of the box, per the "reuse, always reuse" design): the only thing
  # that differs is the content widget (Paragraph vs Markdown) and the
  # footer label. Both 2-tuples (no attribution) and 3-tuples (carrying
  # the agent name) render — the 2-tuple form shows a neutral footer.
  defp entry_widgets({:user, text, agent}, w, _te) do
    h = TranscriptView.height({:user, text, agent}, w, nil)

    widget = %Paragraph{
      text: text,
      style: Styles.role(:text),
      block:
        TranscriptView.agent_block(
          TranscriptView.user_footer(agent),
          Styles.role(:user)
        )
    }

    [{widget, h}]
  end

  defp entry_widgets({:assistant, text, agent}, w, _te) do
    # placement height includes the air rows; the widget rect covers
    # the content + border rows only, so the air rows below stay
    # background (same convention as the old assistant entries)
    h = TranscriptView.height({:assistant, text, agent}, w, nil) - TranscriptView.air()

    [
      {%Markdown{
         content: text,
         style: Styles.role(:text),
         wrap: true,
         block:
           TranscriptView.agent_block(
             TranscriptView.agent_footer(agent),
             Styles.role(:muted)
           )
       }, max(h, 1)}
    ]
  end

  # Thinking is rendered as MARKDOWN like the answer (opencode parity):
  # headings, lists, inline/fenced code carry structure instead of
  # arriving as flat dim text. No "· thinking: " prefix — it would be
  # parsed as prose and break a heading on line 1 — so the dim+italic
  # base style is the only signal that this block is the model's
  # reasoning, not its answer. The widget struct is built by
  # TranscriptView (measure = paint contract), never here.
  #
  # `text` is already in DISPLAY shape: display_entries/1 runs
  # render_reasoning/1 over every entry before the viewport hands it
  # here, so re-normalising would re-harden the whole trace a second
  # time per frame (the stream render throttle bounds how often, but the
  # work is pure duplication).
  defp entry_widgets({:reasoning, text}, w, _te) do
    h = TranscriptView.height({:reasoning, text}, w, nil) - TranscriptView.air()

    [
      {%Markdown{
         content: text,
         style: Styles.role(:reasoning),
         wrap: true
       }, max(h, 1)}
    ]
  end

  defp entry_widgets({:assistant, text}, w, _te) do
    # placement height includes the air rows; the widget rect covers
    # the content only, so the air rows below stay background
    h = TranscriptView.height({:assistant, text}, w, nil) - TranscriptView.air()

    [%Markdown{content: text, style: Styles.role(:text), wrap: true}]
    |> List.update_at(0, &{&1, max(h, 1)})
  end

  defp entry_widgets({:tool, id, name, content}, _w, open_id) when id != open_id do
    line = "▸ #{name}: #{first_line(content)}"

    [{%Paragraph{text: line, style: Styles.role(:muted)}, 1}]
  end

  defp entry_widgets({:tool, id, name, content}, w, _open_id) do
    # rect covers content + border rows only (h - air); the air rows
    # below stay background — same convention as assistant entries
    h = TranscriptView.height({:tool, id, name, content}, w, id) - TranscriptView.air()

    widget = %Paragraph{
      text: "▾ #{name}\n" <> content,
      style: Styles.role(:muted),
      block: Styles.panel(title: " tool output ")
    }

    [{widget, h}]
  end

  # Compaction/notice lines carry the agent that triggered them; a bare
  # info (no agent, e.g. resumed notices) renders the same dim line.
  defp entry_widgets({:info, text, _agent}, _w, _te) do
    [{%Paragraph{text: "  " <> text, style: Styles.role(:muted)}, 1}]
  end

  # Display shape of the thinking buffer, shared by measure, paint and
  # persistence so all three see the same string. Two independent jobs,
  # kept separate because they have different reasons to exist:
  #
  # 1. `harden_line_breaks/1` — VISUAL line structure, load-bearing.
  #    CommonMark treats a lone "\n" as a SOFT break that joins lines
  #    ("line one line two"), but a reasoning trace is line-structured,
  #    so each non-blank line that has a following line gets a HARD break
  #    (two trailing spaces). Markdown still parses headings/bold/code;
  #    the lines just stay lines. It also skips fenced code so literal
  #    text is not corrupted.
  #
  # 2. The trailing "\n" trim — a BUFFER/WINDOW consistency invariant,
  #    not a markdown concern. A trailing newline is a phantom empty row
  #    in the window math (the "scroll up three screens of blanks" bug),
  #    so the displayed string must never end in "\n"; the consumers that
  #    append "\n" (window math, persistence) rely on that.
  #
  # Runs of blank lines need no handling: CommonMark collapses them to a
  # single paragraph break on its own. The old Paragraph-era "runaway
  # blanks" squeeze is obsolete.
  defp render_reasoning(text) do
    text
    |> String.replace_trailing("\n", "")
    |> harden_line_breaks()
  end

  # Two trailing spaces = CommonMark hard break, applied to every
  # non-blank line that has a following line. Lines inside a ``` fence
  # and the fence markers themselves are skipped: code blocks preserve
  # their own newlines and injected spaces corrupt the literal text.
  # Idempotent (a line already ending in "  " is left alone) because it
  # runs again when an entry is restored and whenever display shape is
  # rebuilt.
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

  # Append a streamed delta to the IN-ORDER stream buffer. A delta of the
  # SAME kind extends the last block; a kind SWITCH opens a new block, so
  # reasoning and answer text keep their interleaved arrival order
  # (opencode-style: a statement made between thoughts stays there). The
  # cursor "▌" is not stored here — streaming_entries/1 appends it to the
  # last assistant block at render time.
  defp append_stream([], kind, delta), do: [{kind, normalize_block(kind, delta)}]

  defp append_stream(stream, kind, delta) do
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

  # The in-flight stream as display entries, in order; the last assistant
  # block carries the cursor. Reasoning blocks are trimmed so every
  # consumer (measure, viewport, widget) sees the same string the widget
  # paints — the raw buffer keeps its trailing "\n" and the window math
  # overcounted the phantom row per frame (found live: 'scroll up three
  # screens of blanks').
  defp streaming_entries(%{stream: []}), do: []

  defp streaming_entries(%{stream: stream}) do
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

  # Persist the in-flight stream as transcript entries, in arrival order.
  # `final_text` is the authoritative answer from the session; when no
  # assistant delta streamed (non-streamed/resumed turns) it becomes the
  # single assistant entry.
  defp persist_stream([], nil), do: []

  defp persist_stream([], final_text), do: [{:assistant, breathe(final_text)}]

  defp persist_stream(stream, final_text) do
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

  # Finished thinking becomes a transcript entry (capped — a long
  # reasoning trace must not eat the screen; the full fidelity lives in
  # the core session). nil when there was nothing to persist.
  defp persist_reasoning(reasoning) do
    case reasoning |> render_reasoning() |> String.trim() do
      "" ->
        nil

      text ->
        lines = String.split(text, "\n")

        capped =
          if length(lines) > @thinking_cap,
            do: Enum.take(lines, @thinking_cap) |> Enum.join("\n"),
            else: text

        {:reasoning, capped}
    end
  end

  # (info rects stay 1 row; the air below is background)

  defp first_line(text), do: text |> String.split("\n") |> List.first() |> String.slice(0, 80)

  # The full display list, each entry carrying the agent of the turn it
  # belongs to. turn_agents[i] attributes the i-th USER turn (seeded on
  # mount from the session, extended at send time with the next agent);
  # every entry up to the next user belongs to that turn. Compaction and
  # other info lines are attributed to the agent that triggered them (the
  # turn's agent). Reasoning stays unattributed by design. Streaming
  # entries (not yet in transcript) carry the active (live) turn's agent.
  defp display_entries(state) do
    agents = Map.get(state, :turn_agents) || []

    {transcript, _turn, _last} =
      Enum.reduce(state.transcript || [], {[], 0, nil}, fn entry, {acc, turn, last} ->
        case entry do
          {:user, t} ->
            agent = Enum.at(agents, turn)
            {acc ++ [{:user, t, agent}], turn + 1, agent}

          {:assistant, t} ->
            # attribute to the CURRENT turn's agent; when the turn_agents
            # seed hasn't been extended locally yet (a fresh session, or an
            # agent-less one where the local send never recorded a name),
            # fall back to the live turn's agent from {:turn_started, ...}
            # so the assistant box footer shows the real agent, not the
            # neutral "agent" label.
            agent = last || Map.get(state, :active_agent)
            {acc ++ [{:assistant, t, agent}], turn, last}

          {:info, t} when is_binary(t) ->
            agent = last || Map.get(state, :active_agent)
            {acc ++ [{:info, t, agent}], turn, last}

          {kind, _} when kind in [:reasoning, :tool] ->
            # persisted reasoning is trimmed too (the window math must
            # see the same string the widget paints)
            entry =
              case entry do
                {:reasoning, t} -> {:reasoning, render_reasoning(t)}
                other -> other
              end

            {acc ++ [entry], turn, last}

          other ->
            {acc ++ [other], turn, last}
        end
      end)

    # The live (streaming) entries carry the CURRENT turn's agent: the
    # last recorded turn agent when there is one, else the active_agent
    # (from {:turn_started, ...}) — the same fallback the transcript
    # path uses, so a streamed answer and its persisted form agree.
    live_agent =
      case List.last(agents) do
        a when a != nil -> a
        _ -> Map.get(state, :active_agent)
      end

    streaming =
      streaming_entries(state)
      |> Enum.map(fn
        {:assistant, t} -> {:assistant, t, live_agent}
        other -> other
      end)

    transcript ++ streaming
  end

  # The transcript pane shows a WINDOW of the lines: the last
  # `pane_height` lines when scroll_offset is 0 (auto-follow), else a
  # window ending scroll_offset lines above the bottom (scrolled back).
  # Overflow beyond the pane is what produced the "writes below the
  # screen" report — Paragraphs clip at their area, so we pre-window.

  defp composer(state) do
    # The composer panel (UI.Composer): the input field plus its meta row
    # on ONE chrome surface. All the geometry and the look live there —
    # this module only resolves the VALUES (the setup identity and the
    # transient note) and hands them over.
    #
    # This row is SETUP — what the NEXT input will use. The status of the
    # RUNNING turn lives in the live band above the field (see there).
    Composer.new(
      textarea: state.textarea,
      placeholder: "Message the agent… (alt-enter sends)",
      agent: Map.get(state, :next_agent),
      # the effective model: the next agent's own definition wins over the
      # session's (the row must name the model the NEXT input would use)
      model: Map.get(state, :next_agent_model) || Map.get(state, :model),
      note: esc_hint(state) || Map.get(state, :menu_note),
      diagnostics: if(Map.get(state, :debug_visible?, false), do: scroll_diagnostics(state))
    )
  end

  # The live band (UI.LiveBand): the row between the transcript and the
  # input that says what the RUNNING turn is doing — which agent and
  # model are executing it, plus the status glyph/word and the elapsed
  # context. Identity and status can differ from the composer's SETUP
  # row BELOW, which is the whole reason it exists (Tab changes the next
  # agent; the running turn keeps its own until the turn boundary). The
  # clock is resolved here, the words there.
  defp live_band(state) do
    {agent, model} = band_identity(state)

    LiveBand.new(
      agent: agent,
      model: model,
      status: state.status,
      provider_down?: Map.get(state, :provider_down?, false),
      spin: Map.get(state, :spin, 0),
      elapsed_s: band_elapsed_s(state),
      label: band_label(state)
    )
  end

  # -- Subagent tabs (ADR 018) -------------------------------------------------

  # Subscribe to a child's channel for its tab. Best effort: the child may
  # already be gone (a fast delegation that finished before this event was
  # processed, or a synthetic test event with no live child) — a missing
  # child is not an error, the tab simply has no live stream.
  defp subscribe_child(child_id) do
    Session.subscribe(child_id)
  catch
    :exit, _ -> :ok
  end

  # A child tab's state: its own transcript and stream (folded from its
  # events, exactly like the parent's), its own scroll/open state so a tab
  # scroll never moves the parent, and the identity the band and tab bar
  # show. `finished?` flips at :subagent_finished; the tab is then kept
  # (read-only) until the view is discarded.
  defp child_state(agent, model) do
    %{
      agent: agent,
      model: model,
      finished?: false,
      transcript: [],
      stream: [],
      open_tool_id: nil,
      scroll_offset: 0
    }
  end

  # Fold one relayed child event into its tab. The vocabulary is the
  # session event set; only the events that shape what the user SAW are
  # recorded (deltas, answers, tools, info). The child's events arrive on
  # the parent's channel tagged with the child id (Events.publish), and
  # the router sends them here — never into the parent transcript.
  defp accumulate_child(state, child_id, event) do
    child = Map.fetch!(state.subagents, child_id)
    %{touch(state) | subagents: Map.put(state.subagents, child_id, fold_child(child, event))}
  end

  defp fold_child(child, {:llm_deltas, delta}),
    do: %{child | stream: append_stream(child.stream, :assistant, delta)}

  defp fold_child(child, {:reasoning_deltas, delta}),
    do: %{child | stream: append_stream(child.stream, :reasoning, delta)}

  defp fold_child(child, {:llm_message, text}),
    do: %{
      child
      | transcript: child.transcript ++ persist_stream(child.stream, text),
        stream: []
    }

  defp fold_child(child, {:tool_executed, name, content, _args}),
    do: fold_child(child, {:tool_executed, name, content})

  defp fold_child(child, {:tool_executed, name, content}) do
    id = "tool-#{System.unique_integer([:positive])}"
    content = cap_lines(content, @tool_cap)

    %{
      child
      | transcript:
          child.transcript ++
            persist_stream(child.stream, nil) ++ [{:tool, id, name, content}],
        stream: []
    }
  end

  defp fold_child(child, {:info, text}),
    do: %{child | transcript: child.transcript ++ [{:info, text}]}

  # everything else (status, usage, tool_started, provider) is not part
  # of the child's READING view; ignored rather than guessed at.
  defp fold_child(child, _event), do: child

  # A child's committed transcript + live stream as display entries (the
  # same shapes the parent renderer consumes), every assistant/info entry
  # attributed to the child's own agent.
  defp child_display_entries(child) do
    agent = Map.get(child, :agent)

    committed =
      Enum.map(Map.get(child, :transcript, []), fn
        {:assistant, t} -> {:assistant, t, agent}
        {:info, t} -> {:info, t, agent}
        other -> other
      end)

    streaming =
      streaming_entries(%{stream: Map.get(child, :stream, [])})
      |> Enum.map(fn
        {:assistant, t} -> {:assistant, t, agent}
        other -> other
      end)

    committed ++ streaming
  end

  # The band names the LEAF of the active delegation while a subagent runs
  # (ADR 018 amendment: "the running agent, whoever that is"), else the
  # primary's running identity. The child runs inside the parent's turn,
  # so the parent's status stays the one shown; only the identity changes.
  defp band_identity(state) do
    sub = Map.get(state, :subagents, %{}) |> Map.get(Map.get(state, :active_subagent))

    case sub do
      %{agent: agent, model: model} ->
        {agent, model}

      _ ->
        {Map.get(state, :running_agent),
         Map.get(state, :running_agent_model) || Map.get(state, :model)}
    end
  end

  # the elapsed context: the TOOL's runtime while a tool is in flight
  # (that is what the reader is waiting on), the silence duration while
  # the model is thinking. NOTHING while the turn is not busy (idle,
  # error, a gate/budget/doom/question pause): a frozen count next to
  # "○ idle" implies the app is waiting out a clock that no longer runs
  # (the pre-band composer gated on `busy?` for exactly this reason).
  defp band_elapsed_s(state) do
    if Styles.busy?(state.status) do
      case Map.get(state, :active_tool) do
        tool when is_binary(tool) -> tool_elapsed_s(state)
        _ -> silence_s(state)
      end
    end
  end

  # the status WORD: the tool names itself while it runs ("running mix"),
  # otherwise the busy turn is "thinking" and a non-busy one carries the
  # badge's own word (nil = let `Styles.status_line/6` choose it). The
  # `busy?` gate also keeps a tool left in flight by a failed turn from
  # labelling a pause "running mix".
  #
  # A pause names ITSELF: the badge only knows `:interrupted` and said
  # "approval needed (y/n/e)" for all four pauses (the known label bug —
  # a budget/doom/question pause pointed at keys that do nothing).
  # Approval keeps the badge's own word (its dialog IS the y/n/e one).
  defp band_label(state) do
    cond do
      Styles.busy?(state.status) ->
        case Map.get(state, :active_tool) do
          tool when is_binary(tool) -> "running #{tool}"
          _ -> "thinking"
        end

      state.status == :interrupted ->
        pause_label(state)

      true ->
        nil
    end
  end

  defp pause_label(state) do
    cond do
      Map.get(state, :budget_prompt) != nil -> "tool budget reached (y/n)"
      Map.get(state, :doom_prompt) != nil -> "repeated call (y/n)"
      Map.get(state, :question_prompt) != nil -> "the agent asked a question"
      true -> nil
    end
  end

  # The esc-confirm hints ("esc again to quit/stop"): the armed double
  # press is the ONE thing the composer must say out loud, because
  # nothing else on screen shows that the app is waiting for a second
  # esc.
  defp esc_hint(state) do
    cond do
      Map.get(state, :quit_confirm?, false) -> "esc again to quit"
      Map.get(state, :stop_confirm?, false) -> "esc again to stop"
      true -> nil
    end
  end

  defp tool_elapsed_s(state) do
    case Map.get(state, :tool_started_at) do
      t when is_integer(t) -> div(now_ms() - t, 1000)
      _ -> nil
    end
  end

  # Transcript rows visible above the input/status areas.
  defp transcript_visible_height(state) do
    if is_integer(state.last_pane_height), do: state.last_pane_height, else: 24
  end

  # Which entry covers screen row `y` (transcript-pane-relative)?
  # Recomputes the same placement the renderer produces this frame — the
  # lazy viewport (ADR 028) returns pane-relative rows directly, so no
  # absolute total is needed.
  defp block_at_row(state, y) do
    {entries, offset, open_id} = active_transcript(state)

    w = content_width(if is_integer(state.last_pane_width), do: state.last_pane_width, else: 78)
    ph = transcript_visible_height(state)

    {_clamped, selected} = TranscriptView.viewport(entries, ph, offset, w, open_id)

    Enum.find_value(selected, fn {entry, rel_top, h} ->
      if y >= rel_top and y <= rel_top + h - 1, do: entry
    end)
  end

  # ctrl-t: open the most recent tool block of the ACTIVE view (or close
  # it if it is open).
  defp toggle_last_tool(state) do
    {entries, _offset, open_id} = active_transcript(state)

    case Enum.reverse(entries) |> Enum.find(&match?({:tool, _, _, _}, &1)) do
      {:tool, id, _, _} ->
        open = if open_id == id, do: nil, else: id
        put_open_id(state, open) |> clamp_scroll_now()

      nil ->
        state
    end
  end

  # Toggle the left panel. Hidden also re-clamps the scroll: the pane
  # re-measures wider (content_width), so a stale offset from the narrow
  # layout could sit past the new max (the stale-offset lesson).
  defp toggle_sidebar(state) do
    state
    |> Map.update!(:sidebar_visible?, &(not &1))
    |> clamp_scroll_now()
  end

  # The subagent tab bar (ADR 018): a one-row strip naming the active
  # children (up to @tab_bar_cap) plus a "+N finished" count, and marking
  # which tab the transcript pane is showing. Bounded however many ran;
  # "all" reach through the ctrl-x "subagents" popup. Navigation is by
  # that popup, not by clicking (the bar is read-only, like the band).
  @tab_bar_cap 5

  defp tab_bar(state) do
    subs = Map.get(state, :subagents, %{})
    active_tab = active_tab_id(state)

    {running, finished} =
      subs
      |> Enum.sort_by(fn {_id, c} -> Map.get(c, :agent) end)
      |> Enum.split_with(fn {_id, c} -> not Map.get(c, :finished?, false) end)

    shown = Enum.take(running, @tab_bar_cap)
    hidden_running = length(running) - length(shown)

    primary = tab_label("primary", active_tab == nil)

    tabs = Enum.map(shown, fn {id, c} -> tab_label(Map.get(c, :agent), id == active_tab) end)

    counts =
      []
      |> maybe_count(hidden_running, "running")
      |> maybe_count(length(finished), "finished")

    %Paragraph{
      text: "  " <> Enum.join([primary | tabs] ++ counts, "  "),
      style: Styles.role(:muted)
    }
  end

  defp tab_label(name, true), do: "[#{name}]"
  defp tab_label(name, false), do: " #{name} "
  defp maybe_count(acc, 0, _word), do: acc
  defp maybe_count(acc, n, word), do: acc ++ ["+#{n} #{word}"]

  defp sidebar_widget(state) do
    usage = CodingAgent.Core.Session.Usage.from_map(Map.get(state, :session_usage))
    window = CodingAgent.Core.Config.context_window_tokens()

    # ONE reader of the compaction policy: the sidebar renders the same
    # trigger/warn numbers the Compactor decides on (the old copies
    # re-read the config key and re-hardcoded the 0.8 fraction).
    trigger = Compactor.trigger()
    warn_at = Compactor.warn_threshold()

    # per-frame UserConfig.load removed (the CPU storm): the sidebar
    # renders the value the LIVE SESSION resolved (state.session_effort,
    # read once per mount, ADR 029) — the same one wire_request/2 puts on
    # the request. A config re-read here would show the global layer even
    # when the running session honoured a project override.
    effort = Map.get(state, :session_effort)

    # last turn's context size (ground truth from the provider) drives
    # the % line; cumulative totals are separate. `Usage.last_input_tokens/1`
    # is the one reader (heals a legacy map too); usage is a struct by
    # this point (from_map/1 above), so no map-guard needed.
    last_in = Usage.last_input_tokens(usage)
    pct = trunc(last_in * 100 / max(window, 1))

    # pre-compaction notice territory: the Compactor's warn threshold
    pct_role = if last_in >= warn_at, do: :warning, else: :text

    running = Map.get(state, :running_agent)
    next_agent = Map.get(state, :next_agent)
    busy? = state.status in [:running, :interrupting]

    # -- the two blocks --------------------------------------------------------
    # The panel answers three questions in three visually separated
    # blocks, top to bottom:
    #
    #   * the HEADING: which repo is this session scoped to ("wo arbeite
    #     ich") — a body line in `:emphasis`, not a `Block` title (a
    #     one-sided border paints a title as bare text one cell in from
    #     the edge, which reads as neither heading nor content);
    #   * WHO acts: the agent (with the running/next split while a turn
    #     is in flight), the model it runs on — split into its two halves,
    #     so nothing is clipped — and the session id;
    #   * WHAT it costs: the effort knob TOGETHER with the token rows it
    #     belongs with (the decimal-aligned list), then the cost line.
    #
    # Labels are per-block for a reason: `definition_list/2` pads to the
    # widest label of ITS list, so the identity block pads to "provider"
    # (8) and the stats block to "compacts at" (11) — one list would pad
    # every identity row by three cells to accommodate a stats label.
    identity =
      agent_rows(running, next_agent, busy?) ++
        model_rows(Map.get(state, :model)) ++
        [{"session", String.slice(state.session_id, 0, 22)}]

    stats =
      [
        {"effort", effort_name(effort)},
        {"tokens in", {:decimal, fmt_k(Usage.input_tokens(usage)), nil}},
        {"tokens out", {:decimal, fmt_k(Usage.output_tokens(usage)), nil}},
        {"context", {:decimal, fmt_k(last_in), " (#{pct}% win)"}, pct_role},
        {"compacts at", {:decimal, fmt_k(trigger), " tok"}, pct_role}
      ]

    cost_line =
      case usage.cost do
        c when is_number(c) and c > 0 ->
          Styles.definition_list([{"cost", "$#{Float.round(c, 4)}"}], :sidebar)

        _ ->
          []
      end

    help = [
      Styles.gap(),
      Styles.section_header("ctrl-t toggles tools", :sidebar),
      Styles.section_header("ctrl-x p hides panel", :sidebar)
    ]

    lines =
      [Styles.heading(scope_name(Map.get(state, :scope_root)), :sidebar), Styles.gap()] ++
        Styles.definition_list(identity, :sidebar) ++
        [Styles.gap()] ++
        Styles.definition_list(stats, :sidebar) ++ cost_line ++ help

    %Paragraph{
      text: lines,
      # the whole panel carries the sidebar fill, so the gaps between
      # role-styled spans are filled too (a patchy fill looked broken)
      style: Styles.surface(:sidebar),
      # NO title: the heading is the first BODY line (see above). The
      # panel keeps one border — the separating rule against the
      # transcript, not a frame.
      block: Styles.panel(borders: [:right], surface: :sidebar)
    }
  end

  # The identity rows for the agent slot (B4/ADR 018). While a turn is IN
  # FLIGHT, running and next are BOTH shown so they can differ (Tab only
  # changes the next turn's agent); when idle only the next agent is
  # shown, because `running_agent` keeps the last turn's value. The value
  # carries the `:agent` role (cyan) so the identity keeps the colour the
  # badge gave it.
  defp agent_rows(running, next_agent, busy?) do
    cond do
      not busy? ->
        [{"agent", next_agent, :agent}]

      is_binary(running) and is_binary(next_agent) and running != next_agent ->
        [
          {"agent", "#{running} running", :agent},
          {"agent", "#{next_agent} next", :agent}
        ]

      is_binary(running) ->
        [{"agent", "#{running} running", :agent}]

      is_binary(next_agent) ->
        [{"agent", "#{next_agent} next", :agent}]

      true ->
        [{"agent", nil, :agent}]
    end
  end

  # The model rows: the spec's two halves on their own rows.
  #
  # A model spec is "<provider>:<model id>" and the sidebar used to show
  # it as ONE 32-char-clipped badge ("model ollama_cloud:deepseek-v4.1-fl…"):
  # the version that distinguishes one model from another was exactly
  # what got cut. Split, both halves fit whole. The split rule is the one
  # `Request.build/2` and `ProviderHealth.probe_model/2` already use, so
  # the panel names the same two things the wire request does. A spec
  # with no colon names no provider: the `provider` row is then omitted
  # rather than filled with a guessed one. A missing model reads as the
  # definition list's em dash, like every other absent value.
  defp model_rows(model) do
    case split_model_spec(model) do
      {id, nil} -> [{"model", id, :model}]
      {id, provider} -> [{"model", id, :model}, {"provider", provider, :model}]
    end
  end

  # "<provider>:<model id>" -> {id, provider}; a bare id -> {id, nil}.
  defp split_model_spec(model) when is_binary(model) and model != "" do
    case String.split(model, ":", parts: 2) do
      [provider, id] -> {id, provider}
      [id] -> {id, nil}
    end
  end

  defp split_model_spec(_), do: {nil, nil}

  # The panel heading: the repo this session is scoped to, as its last
  # path segment (the full path is far wider than the 36-column panel).
  # A scope with no basename ("/") or no scope at all (a half-built
  # state) falls back to something printable rather than a blank heading.
  defp scope_name(root) when is_binary(root) and root != "" do
    case Path.basename(root) do
      "" -> root
      name -> name
    end
  end

  defp scope_name(_), do: "—"

  defp fmt_k(n) when n < 1000, do: "#{n}"
  defp fmt_k(n), do: "#{trunc(n / 100) / 10}k"

  # The reasoning-effort label for the sidebar (ADR 029). The session
  # stores req_llm's canonical atom; `nil` means no override on the wire,
  # which reads as "default" (the provider's own default).
  defp effort_name(nil), do: "default"
  defp effort_name(effort) when is_atom(effort), do: Atom.to_string(effort)
  defp effort_name(effort), do: to_string(effort)

  # -- Agent slots (ADR 018) ---------------------------------------------------

  # The session's current agent name, or nil.
  defp session_agent(id) do
    case Session.state(id) do
      {:ok, %{agent: %{name: name}}} -> name
      _ -> nil
    end
  end

  # The persisted per-turn attribution (empty for a fresh session, and
  # always safe for older snapshots that predate the field).
  defp session_turn_agents(id) do
    case Session.state(id) do
      {:ok, %{turn_agents: agents}} when is_list(agents) -> agents
      _ -> []
    end
  end

  # The session's scope root (agents can be project-scoped). Falls back to
  # the process cwd for the picker, where no session exists yet.
  defp session_scope(id) do
    case Session.state(id) do
      {:ok, %{scope_root: root}} when is_binary(root) -> root
      _ -> File.cwd!()
    end
  end

  # The model the session will actually put on the wire (`State.effective_model/1`:
  # the running agent's pinned model, else the session's). The live band
  # reads this instead of re-deriving from the definition cache — the
  # cache can lag a mid-turn switch, and the session's own answer is the
  # one the request uses.
  defp session_effective_model(id) do
    case Session.state(id) do
      {:ok, st} -> CodingAgent.Core.Session.State.effective_model(st)
      _ -> nil
    end
  end

  # The primary agents available to switch between (Tab), for a scope.
  # Sourced from the definitions; on any load error we fall back to no
  # switching rather than crashing the UI (the session itself raises on a
  # bad definition, so a broken set never reaches here).
  #
  # `Agent.selectable?/1` (ADR 029) is the rule: `:all` agents are
  # selectable here too (the old `mode == :primary` filter silently
  # dropped them, so an unpinned definition never appeared), and `hidden`
  # ones never are.
  defp primary_agent_names(scope_root) do
    case CodingAgent.Core.Agent.load(scope_root) do
      {:ok, agents} ->
        agents |> Enum.filter(&CodingAgent.Core.Agent.selectable?/1) |> Enum.map(& &1.name)

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  # The agent's own model, or nil (the definition left it unset).
  defp agent_model(_scope_root, nil), do: nil

  defp agent_model(scope_root, name) do
    case CodingAgent.Core.Agent.load(scope_root) do
      {:ok, agents} ->
        case Enum.find(agents, &(&1.name == name)) do
          %{model: m} when is_binary(m) and m != "" -> m
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # Tab: cycle next_agent through the primary agents, wrapping at both
  # ends (build -> plan -> build -> …). Never selects the no-agent
  # default — "(none)" is not a usable target (user feedback: Tab must
  # not land on it). A session started agent-less still cycles INTO a
  # primary (nil -> first); a running turn keeps its own agent; only the
  # next input changes, via Session.set_agent/2.
  #
  # The session no longer blocks while a turn streams (the turn runs in
  # a worker; see Session.TurnTaskSupervisor), so this is a plain call.
  # A running turn keeps its agent: the session applies the switch at
  # the turn boundary, which is exactly the ADR 018 semantics.
  defp switch_agent(state) do
    case state.primary_agents do
      [] ->
        status_note(state, "no primary agents to switch")

      names ->
        current = state.next_agent
        next = next_agent_name(names, current)
        scope = session_scope(state.session_id)
        next_model = agent_model(scope, next)

        case Session.set_agent(state.session_id, next) do
          {:ok, _} ->
            # while a turn streams the running slot stays the turn's own
            # agent; idle, it follows the switch
            state =
              if state.status in [:running, :interrupting] do
                %{state | next_agent: next, next_agent_model: next_model}
              else
                %{
                  state
                  | next_agent: next,
                    running_agent: next,
                    next_agent_model: next_model,
                    running_agent_model: next_model
                }
              end

            status_note(state, "agent → #{next || "(none)"}")

          {:error, reason} ->
            status_note(state, "agent switch failed: #{inspect(reason)}")
        end
    end
  end

  # nil -> first; name -> next; last (of the primary list) -> first, so
  # the agent-less default is never a selectable target (user feedback:
  # Tab must not land on "(none)").
  defp next_agent_name(names, nil), do: hd(names)

  defp next_agent_name(names, current) do
    case Enum.find_index(names, &(&1 == current)) do
      nil -> hd(names)
      i when i == length(names) - 1 -> hd(names)
      i -> Enum.at(names, i + 1)
    end
  end

  # Scroll diagnostics (DEVELOPER output, behind `debug_visible?` /
  # ctrl-x d): entries / clamped offset / expand state. It is resolved
  # HERE (this module owns the pane math) and handed to the composer as a
  # plain string — the same division as the clock.
  #
  # No total_height here (ADR 028): the lazy viewport yields the clamped
  # offset, and with lazy measurement the total is deliberately unknown
  # until the walk reaches the top — computing it here would reintroduce
  # the eager cost on every debug frame.
  defp scroll_diagnostics(state) do
    entries = display_entries(state)

    w = content_width(if is_integer(state.last_pane_width), do: state.last_pane_width, else: 78)
    ph = if is_integer(state.last_pane_height), do: state.last_pane_height, else: 24

    {clamped, _selected} =
      TranscriptView.viewport(entries, ph, state.scroll_offset, w, state.open_tool_id)

    open = if state.open_tool_id, do: "open:#{state.open_tool_id}", else: "tools shut"

    "scroll: #{clamped} (#{length(entries)} entries, " <>
      "#{open}, h: #{ph} w: #{w})"
  end

  # Session manager (ADR 020, slice 1): list either this directory's
  # sessions (default) or the whole store (`a`), narrowed by a filter
  # (`/`). Each row shows id, status, age and STORAGE FOOTPRINT (R13);
  # the header shows the total. `d` deletes one, `D` deletes every
  # visible row (the directory bulk delete), `r` renames.
  defp picker_widgets(state, area) do
    visible = picker_visible(state)

    rows =
      visible
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        marker = if i == state.picker_index, do: "❯ ", else: "  "

        status = s.status |> to_string() |> String.pad_trailing(8)
        size = format_bytes(Map.get(s, :size, 0)) |> String.pad_leading(7)

        scope =
          if Map.get(state, :picker_all?, false),
            do: "  " <> short_scope(s.scope_root),
            else: ""

        base =
          "#{marker}#{String.slice(s.id, 0, 22)}  #{status}  " <>
            "#{size}  #{format_age(s.saved_at)}#{scope}"

        # in search mode, show the first matching display row so the hit is
        # legible without opening the session (the match count when >1)
        case Map.get(s, :matches) do
          [%{text: text} | _] = matches ->
            more = if length(matches) > 1, do: " (+#{length(matches) - 1})", else: ""
            base <> "\n     ↳ " <> String.slice(text, 0, 60) <> more

          _ ->
            base
        end
      end)

    header = picker_header(state, visible)
    # the header may be one line (a prompt) or several (store + summary +
    # hints); size the box from its actual line count + 2 border + 1 slack.
    # Rows are one line normally but two in search mode (the match line),
    # so count actual lines, not rows.
    header_lines = length(String.split(header, "\n"))
    row_lines = Enum.reduce(rows, 0, fn r, acc -> acc + length(String.split(r, "\n")) end)

    body = ([header] ++ rows) |> Enum.join("\n")

    h = min(row_lines + header_lines + 3, area.height - 4)
    w = min(78, area.width - 4)
    x = div(max(area.width - w, 0), 2)
    y = div(max(area.height - h, 0), 2)
    rect = %Rect{x: x, y: y, width: w, height: h}

    title = if Map.get(state, :picker_all?, false), do: " all sessions ", else: " sessions "

    widget = %Paragraph{
      text: body,
      style: Styles.surface(:chrome),
      block:
        Styles.panel(
          title: title,
          surface: :chrome,
          border_style: Styles.role(:accent, :chrome)
        )
    }

    [{%Clear{}, rect}, {widget, rect}]
  end

  # The picker header: a prompt when one is armed, otherwise the summary
  # line (count, total footprint, active filter, key hints).
  defp picker_header(state, visible) do
    case state.picker_op do
      {:delete, id} ->
        " Delete #{id}?  (y=confirm, any other key cancels)"

      {:delete_many, ids} ->
        where = if Map.get(state, :picker_all?, false), do: "visible", else: "in this directory"
        " Delete #{length(ids)} session(s) #{where}?  (y=confirm, any other key cancels)"

      {:rename, _id, buf} ->
        " Rename to: #{buf}  (enter=commit, esc=cancel)"

      {:filter, buf} ->
        " Filter: #{buf}▌  (enter=apply, esc=clear)"

      {:search, buf} ->
        " Search content: #{buf}▌  (enter=apply, esc=clear)"

      {:prune, buf} ->
        " Prune sessions older than N days: #{buf}▌  (enter=confirm, esc=cancel)"

      {:prune_size, buf} ->
        " Prune sessions larger than N MB: #{buf}▌  (enter=confirm, esc=cancel)"

      {:prune_confirm, ids, why} ->
        " Delete #{length(ids)} session(s) #{why}?  (y=confirm, any other key cancels)"

      nil ->
        total = visible |> Enum.map(&Map.get(&1, :size, 0)) |> Enum.sum()
        scope = if Map.get(state, :picker_all?, false), do: "all", else: "this dir"

        query = Map.get(state, :picker_search)

        {scope, filter} =
          case query do
            q when is_binary(q) and q != "" -> {"search", "  search: #{q}"}
            _ -> {scope, ""}
          end

        filter =
          case String.trim(Map.get(state, :picker_filter, "")) do
            "" -> filter
            f -> filter <> "  filter: #{f}"
          end

        # the ACTIVE store names itself (ADR 020 R16): sessions from
        # different stores must never be confused for one another
        store = Store.path()

        " store: #{store}\n" <>
          " #{length(visible)} session(s), #{format_bytes(total)}  [#{scope}]#{filter}\n" <>
          "  enter=resume  n=new  a=all/dir  /=filter  s=search  q=quit\n" <>
          "  d=delete  D=delete all  r=rename  e=export md  E=export json\n" <>
          "  P=prune age  S=prune size"
    end
  end

  # A short directory label for the all-store view: the last two path
  # segments, so a row stays scannable.
  defp short_scope(nil), do: ""

  defp short_scope(root) do
    root
    |> Path.split()
    |> Enum.take(-2)
    |> Path.join()
  end

  defp format_bytes(n) when n < 1024, do: "#{n} B"
  defp format_bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 0) |> trunc()} KB"
  defp format_bytes(n), do: "#{Float.round(n / 1024 / 1024, 1)} MB"

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

  defp dialog_widgets(%{deciding?: true}, _area), do: []

  defp dialog_widgets(%{pending: pending} = state, area) do
    pending
    |> Enum.with_index()
    |> Enum.map(fn {call, i} ->
      {_id, name, args} = ToolCall.normalize(call)
      pretty = pretty_args(args)

      # Escalations carry the agent's stated reason (ADR 015): show it
      # first, so the human reads WHY before the raw arguments.
      reason =
        case escalation_reason(name, args) do
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

      # NOTE: widget-level bg + Clear variants both failed headless
      # (bg didn't fill; Clear killed the render cycle). The joined
      # string with per-row spaces renders — bg comes from the
      # widget-level style.
      body =
        text
        |> String.split("\n")
        |> Enum.concat(List.duplicate(" ", max(h - 2 - length(String.split(text, "\n")), 0)))
        |> Enum.join("\n")

      # The gate is a distinct, blocking surface: a double border in the
      # warning role (one meaning per color role). The panel builder owns
      # the border type now — no reaching around it.
      widget = %Paragraph{
        text: body,
        style: Styles.surface(:chrome),
        block:
          Styles.panel(
            title: " APPROVAL #{i + 1}/#{length(pending)} ",
            surface: :chrome,
            border_style: Styles.role(:warning, :chrome),
            border_type: :double
          )
      }

      # cap at the reading measure and center: a wide terminal must
      # not stretch the dialog edge to edge (live report)
      w = min(@measure + 2, area.width - 4)
      rect = overlay_rect(state, area, h, w)
      [{%Clear{}, rect}, {widget, rect}]
    end)
    |> List.flatten()
  end

  # The tool-round budget prompt (ADR 025): a single panel, y continues
  # (another full budget), n stops (the model summarizes and the turn
  # ends). Rendered instead of the approval dialog — a budget pause has
  # no pending tool calls.
  defp budget_widgets(%{budget_prompt: nil}, _area), do: []

  defp budget_widgets(%{budget_prompt: %{budget: budget}} = state, area) do
    text =
      "The turn has used its #{budget}-round tool budget.\n\n" <>
        "y = continue (another #{budget} rounds)   n = stop (summarize)"

    h = min(6, div(area.height, 2))

    body =
      text
      |> String.split("\n")
      |> Enum.concat(List.duplicate(" ", max(h - 2 - length(String.split(text, "\n")), 0)))
      |> Enum.join("\n")

    widget = %Paragraph{
      text: body,
      style: Styles.surface(:chrome),
      block:
        Styles.panel(
          title: " TOOL BUDGET ",
          surface: :chrome,
          border_style: Styles.role(:warning, :chrome),
          border_type: :double
        )
    }

    w = min(@measure + 2, area.width - 4)
    rect = overlay_rect(state, area, h, w)
    [{%Clear{}, rect}, {widget, rect}]
  end

  # The doom-loop prompt (ADR 026): a single panel, y continues the
  # repeated round, n rejects it (steers the model off the repetition).
  defp doom_widgets(%{doom_prompt: nil}, _area), do: []

  defp doom_widgets(%{doom_prompt: %{tool: tool}} = state, area) do
    text =
      "Repeated call detected: #{tool} was called 3 times with identical\n" <>
        "arguments. This is usually a loop.\n\n" <>
        "y = continue (run it anyway)   n = reject (change approach)"

    h = min(7, div(area.height, 2))

    body =
      text
      |> String.split("\n")
      |> Enum.concat(List.duplicate(" ", max(h - 2 - length(String.split(text, "\n")), 0)))
      |> Enum.join("\n")

    widget = %Paragraph{
      text: body,
      style: Styles.surface(:chrome),
      block:
        Styles.panel(
          title: " DOOM LOOP ",
          surface: :chrome,
          border_style: Styles.role(:warning, :chrome),
          border_type: :double
        )
    }

    w = min(@measure + 2, area.width - 4)
    rect = overlay_rect(state, area, h, w)
    [{%Clear{}, rect}, {widget, rect}]
  end

  # The question wizard (ADR 027): the current question, its options as a
  # definition list, the always-present "type your own" row, and the
  # controls.
  #
  # The body is MARKDOWN painted by the Markdown widget, not a hand-sized
  # Paragraph: markdown wraps long question and description text natively,
  # so nothing clips at the panel edge (the old plain-Paragraph wizard
  # lost half of a long question on a narrow window, found live). Options
  # use the definition-list form — the bold TERM is the key row
  # ("**1) fd**"), the DESCRIPTION hangs below it prefixed with ": " —
  # because tui-markdown turns bare digit-led lines into lists and
  # RENUMBERS them ("1) fd" renders as "1." and "0)" becomes "3."), which
  # would break the digit keys. Bold keeps "1)" literal. Measured and
  # painted by the same probe the transcript uses (measure = paint).
  defp question_widgets(%{question_prompt: nil}, _area), do: []

  defp question_widgets(%{question_prompt: qp} = state, area) do
    question = Enum.at(qp.questions, qp.index)
    options = question["options"] || []

    body = question_markdown(question, qp, options)

    # The probe measures the boxless markdown at the rect's INNER width;
    # the panel's border adds the 2 rows back. Verified against the drawn
    # buffer at 100/62/40 cols: the bottom border lands on the rect's
    # last row, nothing clipped (the boxed widget wraps one column
    # tighter than the boxless probe on both sides, which the height's
    # last-nonblank metric absorbs).
    w = min(@measure + 2, area.width - 4)
    h = min(TranscriptView.height({:reasoning, body}, w - 2, nil) + 2, area.height - 2)

    title =
      case question["header"] do
        hdr when is_binary(hdr) and hdr != "" -> hdr
        _ -> "QUESTION"
      end

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

    rect = overlay_rect(state, area, h, w)
    [{%Clear{}, rect}, {widget, rect}]
  end

  # The wizard body in markdown. Terms are hard-wrapped single lines
  # (option rows must stay rows — a description never merges into the
  # next term's line), options separated by blank-QUOTE separators (see
  # options_deflist — a plain blank line paints with no gap); the
  # "type your own" row is an answer row like any other, so it gets the
  # same separator. tui-markdown renders the description on its own
  # ": " line (the definition-list look, verified against the painted
  # buffer).
  defp question_markdown(question, qp, options) do
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
  # (literal inside **…**), the description hangs below as ": …". Blocks
  # are separated by an EMPTY BLOCKQUOTE (`>`): the def-list parser eats
  # blank lines between blocks (measured — "\n\n" paints with no gap), so
  # a plain paragraph separator shows nothing. A blockquote opens a new
  # top-level block, which ratatui's spacer paints as a blank row even
  # when empty — and a description or label containing "> x" merges into
  # the def-list paragraph (lazy continuation) instead of breaking it.
  #
  # Labels, descriptions and the custom buffer are MODEL/USER text
  # embedded in that structure, so each is reduced to ONE line first: a
  # newline inside a label leaves the bold term unclosed and a blank line
  # in a description escapes the def-list (measured — "evil\n>\n\n## x"
  # painted as a heading). Flattening whitespace keeps the option rows
  # rows, which is the structure's contract.
  defp options_deflist(options, selected) do
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

  # The always-present "type your own" row; while a custom answer is
  # being typed it carries the buffer and the cursor.
  defp custom_entry(nil), do: "**0) type your own answer…**"
  defp custom_entry(buf), do: "▸ **0) #{single_line(buf)}▏**"

  # One line, always: whitespace runs (newlines included) collapse to a
  # single space, so embedded text cannot open a markdown block or close
  # its own emphasis.
  defp single_line(nil), do: ""
  defp single_line(text) when is_binary(text), do: text |> String.split() |> Enum.join(" ")
  defp single_line(_), do: ""

  # A paragraph's own newlines must not open new blocks: make them hard
  # breaks so the question's line structure survives the markdown parse.
  defp hard_breaks(text), do: String.replace(text, "\n", "  \n")

  # The agent's stated reason for an escalation (ADR 015), for display.
  # Only meaningful for `shell`; other tools have no escalations.
  defp escalation_reason("shell", args) do
    case Map.get(args, "reason") || Map.get(args, :reason) do
      r when is_binary(r) and r != "" -> r
      _ -> nil
    end
  end

  defp escalation_reason(_name, _args), do: nil

  # `reason` is rendered separately as "why:", and the escalation booleans
  # are shown by the reason itself — omit them from the raw argument list
  # so the dialog does not say the same thing twice.
  @hidden_args ~w(reason network git_write)

  defp pretty_args(args) do
    args
    |> Enum.reject(fn {k, _} -> to_string(k) in @hidden_args end)
    |> Enum.map(fn {k, v} ->
      v_str = if is_binary(v) and String.contains?(v, "\n"), do: inspect(v), else: to_string(v)
      "#{k}: #{String.slice(v_str, 0, 160)}"
    end)
    |> Enum.join("\n")
  end
end
