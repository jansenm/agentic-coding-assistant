# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.State do
  @moduledoc """
  The TUI's state, defined ONCE.

  `ui/tui.ex` used to define the state twice — `mount_picker/4` (53
  fields) and `mount_session/3` (64) held the same record as two
  anonymous map literals. Adding a field meant editing two places; a
  field that existed in only one literal was absent at the other; the
  33 `Map.get(state, :k, default)` call sites existed because the code
  could not know whether a field was there; and one field
  (`:last_pane_rect`) was never declared anywhere — written with
  `Map.put/3`, read with `Map.get/2`, invisible to the compiler. The
  record now has a name and the fields sit in the groups the tui.ex
  split followed (the `# --` sections).

  The struct is NOT persisted: it lives in the TUI process, so there is
  no `from_map/1` edge — the two mount shapes are two constructors over
  one `base/1`. `base/1` carries the fields every state has (the neutral
  defaults live in the `defstruct`; what `opts` decides lives here);
  `picker/4` and `session/2` override exactly the fields their shape
  differs in, the field comments of the old literals moved down into the
  `defstruct`. `session/2` builds with `struct!/2`, so a field that
  leaves the struct is a crash at that call site, not a silent `nil`.

  The remaining anonymous maps inside it (`:menu_popup`, `:file_popup`,
  `:command_popup`, `:question_prompt` — each a dialog's value map) are
  dictionaries-of-the-moment, not state groups; they stay maps until a
  slice gives them a module of their own.
  """

  alias CodingAgent.Core.Session.{Timing, Usage}
  alias CodingAgent.UI.{Keymap, Menu, Tabs}
  alias ExRatatui.Layout.Rect

  @typedoc "The TUI driver's whole state: session mirrors, input, transcript, tabs, picker, overlays."
  @type t :: %__MODULE__{
          # -- the session and what it resolved (mirrored at mount, never
          #    re-read per frame: the sidebar runs at poll cadence and must
          #    not call into the session or the config per frame)
          session_id: String.t() | nil,
          model: String.t() | nil,
          scope_root: String.t() | nil,
          status: CodingAgent.Core.Session.State.status(),
          session_usage: Usage.t(),
          timing: Timing.t(),
          trailer_bytes: non_neg_integer(),
          session_effort: atom() | nil,
          compaction_window: non_neg_integer(),
          compaction_soft: non_neg_integer(),
          compaction_hard: non_neg_integer(),
          context_window_source: atom() | nil,
          todos: [map()],
          last_error: term() | nil,
          provider_down?: boolean(),
          # -- the agent slots (ADR 018): running_agent executes the ACTIVE
          #    turn, next_agent is what the NEXT input starts with (Tab
          #    cycles), active_agent the turn's attribution while streaming
          running_agent: String.t() | nil,
          next_agent: String.t() | nil,
          active_agent: String.t() | nil,
          turn_agents: [String.t() | nil],
          primary_agents: [String.t()],
          running_agent_model: String.t() | nil,
          next_agent_model: String.t() | nil,
          # -- transcript & stream: what the pane paints and what is in
          #    flight for the running turn
          transcript: [tuple()],
          stream: [tuple()],
          stream_dirty?: boolean(),
          last_activity_at: integer() | nil,
          spin: non_neg_integer(),
          active_tool: String.t() | nil,
          tool_started_at: integer() | nil,
          # scroll diagnostics are developer output (they render in the
          # composer's meta row when on); off by default, toggled with ctrl-x d
          debug_visible?: boolean(),
          # -- input & composer
          # the textarea handle is an ExRatatui resource reference —
          # base/1 builds it fresh per mount (the same type Composer carries);
          # a mount's returned state always has one, so nil is never hit
          textarea: reference() | nil,
          history: [String.t()],
          history_index: non_neg_integer() | nil,
          history_draft: String.t() | nil,
          # the keymap is loaded ONCE per mount_session, not per keypress
          # (TOML parse in the input hot path was the crash vector); the
          # picker hands off before any key reaches the keymap paths
          keymap: Keymap.t() | nil,
          mount_opts: keyword() | nil,
          # -- dialogs & confirmations: gate interruptions, parked prompts,
          #    armed esc semantics
          pending: [map()],
          pending_edit: term() | nil,
          deciding?: boolean(),
          budget_prompt: %{budget: pos_integer()} | nil,
          doom_prompt: %{tool: String.t()} | nil,
          question_prompt: map() | nil,
          quit_confirm?: boolean(),
          quit_armed_at: integer(),
          stop_confirm?: boolean(),
          stop_armed_at: integer(),
          # -- overlays (menu, popups, esc)
          file_popup: map() | nil,
          command_popup: map() | nil,
          menu_pending: boolean(),
          menu_timer: reference() | nil,
          menu_popup: Menu.t() | nil,
          menu_popup_id: atom() | nil,
          menu_index: non_neg_integer(),
          menu_note: String.t() | nil,
          # -- the view: tabs (ADR 018) and the frame geometry the poll
          #    compares against (`last_pane_rect` is nil before the first
          #    frame, which is why the first poll always paints)
          tabs: Tabs.t(),
          last_pane_rect: Rect.t() | nil,
          # -- the session picker (ADR 020 slice 1): nil picker fields while
          #    a session is attached; `picker_opts`/`picker_prompt` defer the
          #    session start the picker interrupted
          picker: [map()] | nil,
          picker_index: non_neg_integer(),
          picker_opts: keyword() | nil,
          picker_prompt: String.t() | nil,
          picker_op: {:filter, String.t()} | {:search, String.t()} | nil,
          picker_scope: String.t() | nil,
          picker_all?: boolean(),
          picker_filter: String.t(),
          picker_search: String.t() | nil,
          # -- what the harness decides (opts) and the view seeds
          #    (visible by default; tests seed it off to read a clean
          #    transcript buffer without the 36-col sidebar)
          sidebar_visible?: boolean(),
          test_pid: pid() | nil,
          test_mode?: boolean()
        }

  defstruct session_id: nil,
            model: nil,
            scope_root: nil,
            status: :idle,
            session_usage: Usage.new(),
            timing: Timing.new(),
            trailer_bytes: 0,
            session_effort: nil,
            compaction_window: 0,
            compaction_soft: 0,
            compaction_hard: 0,
            context_window_source: nil,
            todos: [],
            last_error: nil,
            provider_down?: false,
            running_agent: nil,
            next_agent: nil,
            active_agent: nil,
            turn_agents: [],
            primary_agents: [],
            running_agent_model: nil,
            next_agent_model: nil,
            transcript: [],
            stream: [],
            stream_dirty?: false,
            last_activity_at: nil,
            spin: 0,
            active_tool: nil,
            tool_started_at: nil,
            # scroll diagnostics: developer output off by default, toggled
            # with ctrl-x d (they render in the composer's meta row)
            debug_visible?: false,
            # textarea and mount_opts are never nil in a returned state: base/1
            # builds both, and neither field has a value a compile-time default
            # could share (the textarea must be fresh per mount)
            textarea: nil,
            history: [],
            history_index: nil,
            history_draft: nil,
            keymap: nil,
            mount_opts: nil,
            pending: [],
            pending_edit: nil,
            deciding?: false,
            budget_prompt: nil,
            doom_prompt: nil,
            question_prompt: nil,
            quit_confirm?: false,
            quit_armed_at: 0,
            stop_confirm?: false,
            stop_armed_at: 0,
            file_popup: nil,
            command_popup: nil,
            menu_pending: false,
            menu_timer: nil,
            menu_popup: nil,
            menu_popup_id: nil,
            menu_index: 0,
            menu_note: nil,
            tabs: Tabs.new(),
            last_pane_rect: nil,
            picker: nil,
            picker_index: 0,
            picker_opts: nil,
            picker_prompt: nil,
            picker_op: nil,
            picker_scope: nil,
            picker_all?: false,
            picker_filter: "",
            picker_search: nil,
            sidebar_visible?: true,
            test_pid: nil,
            test_mode?: false

  @doc """
  The fields every TUI state carries, picker or session: the neutral
  struct defaults plus what the mount decides from opts. The two mount
  shapes are built on top of this one.
  """
  @spec base(keyword()) :: t()
  def base(opts) do
    %__MODULE__{
      mount_opts: opts,
      test_pid: Keyword.get(opts, :test_pid),
      test_mode?: test_session?(opts),
      sidebar_visible?: Keyword.get(opts, :sidebar, true),
      textarea: ExRatatui.textarea_new()
    }
  end

  @doc """
  The picker state (ADR 020 slice 1, user request: on start check if
  there are previous sessions in the current working directory; if yes
  go to the session chooser, if not start a new session). No session is
  attached yet — `picker` holds the source rows, `picker_opts` and
  `picker_prompt` defer the session start the picker interrupted.
  """
  @spec picker(keyword(), [map()], String.t() | nil, String.t()) :: t()
  def picker(opts, sessions, prompt, root) do
    %{
      base(opts)
      | picker: sessions,
        picker_opts: opts,
        picker_prompt: prompt,
        picker_scope: Path.expand(root)
    }
  end

  @doc """
  The session state: a session is attached (fresh or resumed). `fields`
  carries the shape-specific values the mount resolved — the session's
  real model, the agent slots, the mirrored limits, the restored
  transcript and any parked dialogs. `struct!/2` so a field that leaves
  the struct is a crash at the mount, not a silent `nil`.
  """
  @spec session(keyword(), keyword()) :: t()
  def session(opts, fields), do: struct!(base(opts), fields)

  @doc """
  The TUI's test flag, read the same way at every site: the `test_mode`
  OPTION carries the ExRatatui virtual terminal size, and its PRESENCE —
  not its shape — is the flag. One reader, so the picker, the state
  field and the session started from the mount can never disagree about
  whether this is a test run.
  """
  @spec test_session?(keyword()) :: boolean()
  def test_session?(opts), do: Keyword.get(opts, :test_mode) != nil
end
