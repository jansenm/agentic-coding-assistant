# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.Tabs do
  @moduledoc """
  The subagent tabs (ADR 018): the child views, the pointer that says which
  view the pane shows, and each view's own scroll and expand state.

  A session's transcript can be read in more than one place: the primary
  transcript, and one read-only tab per `task` child. They differ in WHAT
  they show, not in how they show it — a child tab runs the parent's own
  display and render path (`UI.Display.child_entries/1`), so this module
  owns only the part that is about the VIEW: which children exist, which
  one is on screen, and where each view is scrolled to.

  ## One pointer, not two

  `active` is a POINTER into `subagents`, never an independent selection: an
  id that is no longer a key reads as the primary view. `active_child/1` is
  the ONE implementation of that rule (F4) — the transcript pane, the scroll
  and expand state, the tab bar, the popup mark and the live band's identity
  all go through it, so a stale pointer cannot make two surfaces disagree
  about which view is showing. `open/2` is the only writer.

  ## Every view keeps its own position

  Scrolling a child tab must never move the primary transcript, and vice
  versa, so `scroll_offset` and `open_tool_id` exist per view: as
  `primary_*` fields here, and as fields of `Child` for a child. The
  accessors (`scroll_offset/1`, `put_scroll/2`, …) dispatch on the ACTIVE
  view, so no caller has to ask "am I on a tab?" first.

  ## A child tab is not a session

  A child's events arrive on the parent's channel tagged with the child id
  (`Events.publish`), and the router sends them here. `fold/3` keeps the ones
  that shape what the human SAW (deltas, answers, tools, info) and ignores
  the rest rather than guessing. A finished child's tab is KEPT (read-only)
  until the view is discarded — the owner keeps every subagent of a session —
  so `finish/3` only closes the stream out and flips `finished?`.

  Nothing here reads a clock or a terminal: `UI.Tui` resolves the event, the
  geometry and the session calls it must make and hands the tab slice over,
  the same division the other painters follow.
  """

  alias CodingAgent.Core.Session
  alias CodingAgent.UI.{Display, Styles}

  defmodule Child do
    @moduledoc """
    One subagent's tab: its own transcript and stream (folded from its
    events, exactly like the parent's), its own scroll/open state, and the
    identity the band and the tab bar show. `finished?` flips at
    `:subagent_finished`; the tab is then kept, read-only.
    """

    @type t :: %__MODULE__{
            agent: String.t() | nil,
            model: String.t() | nil,
            finished?: boolean(),
            transcript: [Display.entry()],
            stream: [Display.block()],
            open_tool_id: String.t() | nil,
            scroll_offset: non_neg_integer()
          }

    defstruct agent: nil,
              model: nil,
              finished?: false,
              transcript: [],
              stream: [],
              open_tool_id: nil,
              scroll_offset: 0
  end

  @type id :: String.t()

  @typedoc """
  The tabs of one session view: the children of THIS view, the pointer that
  selects one of them, and the primary view's own position.
  """
  @type t :: %__MODULE__{
          subagents: %{optional(id()) => Child.t()},
          active: id() | nil,
          primary_scroll_offset: non_neg_integer(),
          primary_open_tool_id: String.t() | nil
        }

  defstruct subagents: %{},
            active: nil,
            primary_scroll_offset: 0,
            primary_open_tool_id: nil

  # The tab bar names the active children (up to this many) plus a "+N"
  # count, and marks which tab the pane is showing. Bounded however many
  # ran; "all" is reachable through the ctrl-x "subagents" popup.
  @tab_bar_cap 5

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Is there no child tab at all? A parent-only session paints no strip."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{subagents: subs}), do: map_size(subs) == 0

  # -- the views -------------------------------------------------------------

  @doc """
  The active child tab as `{id, child}`, or `nil` for the primary view — also
  when the pointer names a tab that no longer exists (F4).
  """
  @spec active_child(t()) :: {id(), Child.t()} | nil
  def active_child(%__MODULE__{active: id, subagents: subs}) when is_binary(id) do
    case Map.fetch(subs, id) do
      {:ok, child} -> {id, child}
      :error -> nil
    end
  end

  def active_child(%__MODULE__{}), do: nil

  @doc "The effective active tab id: `nil` when the pane shows the primary."
  @spec active_id(t()) :: id() | nil
  def active_id(%__MODULE__{} = tabs) do
    case active_child(tabs) do
      nil -> nil
      {id, _child} -> id
    end
  end

  @doc """
  Shows `id`'s tab (`nil` = the primary transcript). The only writer of the
  pointer; the tabs themselves are untouched, so every view keeps the
  position it had when it went out of sight.
  """
  @spec open(t(), id() | nil) :: t()
  def open(%__MODULE__{} = tabs, id) when is_binary(id) or is_nil(id),
    do: %{tabs | active: id}

  @doc "The active view's scroll offset (0 = following the tail)."
  @spec scroll_offset(t()) :: non_neg_integer()
  def scroll_offset(%__MODULE__{} = tabs) do
    case active_child(tabs) do
      nil -> tabs.primary_scroll_offset
      {_id, child} -> child.scroll_offset
    end
  end

  @spec put_scroll(t(), non_neg_integer()) :: t()
  def put_scroll(%__MODULE__{} = tabs, offset) do
    case active_child(tabs) do
      nil -> %{tabs | primary_scroll_offset: offset}
      {id, child} -> put_child(tabs, id, %{child | scroll_offset: offset})
    end
  end

  @doc "The id of the tool block expanded in the active view, if any."
  @spec open_tool_id(t()) :: String.t() | nil
  def open_tool_id(%__MODULE__{} = tabs) do
    case active_child(tabs) do
      nil -> tabs.primary_open_tool_id
      {_id, child} -> child.open_tool_id
    end
  end

  @spec put_open(t(), String.t() | nil) :: t()
  def put_open(%__MODULE__{} = tabs, open) do
    case active_child(tabs) do
      nil -> %{tabs | primary_open_tool_id: open}
      {id, child} -> put_child(tabs, id, %{child | open_tool_id: open})
    end
  end

  @doc """
  The PRIMARY view back to the tail. A new turn's output lands in the primary
  transcript, so a parent scrolled back would hide the turn the human just
  sent; the child tabs keep their own position.
  """
  @spec at_tail(t()) :: t()
  def at_tail(%__MODULE__{} = tabs), do: %{tabs | primary_scroll_offset: 0}

  # -- the children's lifetime ----------------------------------------------

  @doc """
  Opens a tab for a child that just started and subscribes to its channel.
  """
  @spec start(t(), id(), String.t() | nil, String.t() | nil) :: t()
  def start(%__MODULE__{} = tabs, id, agent, model) do
    subscribe(id)
    put_child(tabs, id, %Child{agent: agent, model: model})
  end

  # Subscribe to a child's channel for its tab. Best effort: the child may
  # already be gone (a fast delegation that finished before this event was
  # processed, or a synthetic test event with no live child) — a missing
  # child is not an error, the tab simply has no live stream. The `:exit`
  # that used to be caught here is `Session.subscribe/1`'s own policy now
  # (review N128), so this stays a caller and nothing more.
  defp subscribe(child_id) do
    _ = Session.subscribe(child_id)
    :ok
  end

  @doc """
  Closes a child's tab out when it finishes.

  A child that DIED (a stream error) never emits an `llm_message`, so its last
  reasoning was left in `stream` as an in-flight block that never resolves:
  the tab ended mid-thought with no answer and no sign anything went wrong
  (the error note only reached the PARENT). Commit the lingering stream to
  the transcript and, on error, put the note INSIDE the child's own view so
  the tab tells its own story. An `:ok` child already emitted its
  `llm_message` (stream is empty), so its own commit is a no-op here.
  """
  @spec finish(t(), id(), :ok | :error) :: t()
  def finish(%__MODULE__{} = tabs, id, outcome) do
    # Unsubscribe — the child is stopped, so no further events will come; the
    # registration would otherwise outlive the process as a dead entry.
    Session.unsubscribe(id)

    case Map.fetch(tabs.subagents, id) do
      {:ok, child} ->
        committed =
          child.transcript ++ Display.persist_stream(child.stream, nil)

        committed =
          case outcome do
            :error -> committed ++ [{:info, "· subagent ended with an error"}]
            _ -> committed
          end

        put_child(tabs, id, %{child | finished?: true, transcript: committed, stream: []})

      :error ->
        tabs
    end
  end

  @doc """
  Forwards the human's stop to every active child: a running `task` call blocks
  the parent's turn worker inside the call, so the parent's stop only lands
  after the child — a long delegation would not be cancellable (ADR 018).
  """
  @spec interrupt_running(t()) :: :ok
  def interrupt_running(%__MODULE__{subagents: subs}) do
    for {id, %Child{finished?: false}} <- subs, do: Session.interrupt(id)
    :ok
  end

  # -- folding a child's events ---------------------------------------------

  @doc """
  Folds one relayed child event into its tab. The vocabulary is the session
  event set; only the events that shape what the user SAW are recorded.
  """
  @spec fold(t(), id(), term()) :: t()
  def fold(%__MODULE__{} = tabs, id, event),
    do: put_child(tabs, id, fold_child(Map.fetch!(tabs.subagents, id), event))

  defp fold_child(child, {:llm_deltas, delta}),
    do: %{child | stream: Display.append_stream(child.stream, :assistant, delta)}

  defp fold_child(child, {:reasoning_deltas, delta}),
    do: %{child | stream: Display.append_stream(child.stream, :reasoning, delta)}

  defp fold_child(child, {:llm_message, text}),
    do: %{
      child
      | transcript: child.transcript ++ Display.persist_stream(child.stream, text),
        stream: []
    }

  defp fold_child(child, {:tool_executed, name, content, _args}),
    do: fold_child(child, {:tool_executed, name, content})

  defp fold_child(child, {:tool_executed, name, content}) do
    id = "tool-#{System.unique_integer([:positive])}"
    content = Display.cap_lines(content)

    %{
      child
      | transcript:
          child.transcript ++
            Display.persist_stream(child.stream, nil) ++ [{:tool, id, name, content}],
        stream: []
    }
  end

  defp fold_child(child, {:info, text}),
    do: %{child | transcript: child.transcript ++ [{:info, text}]}

  # everything else (status, usage, tool_started, provider) is not part
  # of the child's READING view; ignored rather than guessed at.
  defp fold_child(child, _event), do: child

  @doc "Is any child streaming text that has not been painted yet?"
  @spec any_stream?(t()) :: boolean()
  def any_stream?(%__MODULE__{subagents: subs}) do
    Enum.any?(subs, fn {_id, child} -> match?([_ | _], child.stream) end)
  end

  # -- what the surfaces show ------------------------------------------------

  @doc """
  The subagent tab bar (ADR 018): a one-row strip naming the active children
  (up to `@tab_bar_cap`) plus a "+N finished" count, and marking which tab the
  transcript pane is showing. `nil` when no child tab exists, so a parent-only
  session has no strip at all.

  The strip is part of the bottom box: `UI.Composer.placements/2` renders it
  inside the composer's rect and `UI.Composer.height/1` counts it.
  """
  @spec tab_line(t()) :: ExRatatui.Text.Line.t() | nil
  def tab_line(%__MODULE__{subagents: subs}) when map_size(subs) == 0, do: nil

  def tab_line(%__MODULE__{subagents: subs} = tabs) do
    {running, finished} =
      subs
      |> Enum.sort_by(fn {_id, c} -> c.agent end)
      |> Enum.split_with(fn {_id, c} -> not c.finished? end)

    shown = Enum.take(running, @tab_bar_cap)
    hidden_running = length(running) - length(shown)

    labels = ["primary" | Enum.map(shown, fn {_id, c} -> c.agent end)]

    counts =
      [{hidden_running, "running"}, {length(finished), "finished"}]
      |> Enum.reject(fn {n, _} -> n == 0 end)

    # the row is on the chrome surface (inside the composer panel);
    # Styles owns the roles and the accent-vs-muted split
    Styles.tab_line(labels, active_name(tabs), counts)
  end

  # the agent name of the active tab (nil = the primary tab), so the label
  # can be accented
  defp active_name(%__MODULE__{} = tabs) do
    case active_child(tabs) do
      {_id, %Child{agent: name}} -> name
      nil -> nil
    end
  end

  @doc """
  The rows of the ctrl-x "subagents" popup: one per child of THIS view plus a
  "primary" row back to the parent transcript. Finished children are listed
  after the active ones. Items carry `{:tab, child_id | nil}` as `id`.
  """
  @spec popup_items(t()) :: [map()]
  def popup_items(%__MODULE__{subagents: subs} = tabs) do
    active = active_id(tabs)

    primary = %{
      id: {:tab, nil},
      label: "primary transcript",
      status: nil,
      action: :open_tab
    }

    children =
      subs
      |> Enum.sort_by(fn {_id, c} -> {c.finished?, c.agent} end)
      |> Enum.map(fn {id, c} ->
        mark =
          cond do
            id == active -> " (viewing)"
            c.finished? -> " (finished)"
            true -> " (running)"
          end

        %{
          id: {:tab, id},
          label: "#{c.agent} · #{c.model}#{mark}",
          status: nil,
          action: :open_tab
        }
      end)

    [primary | children]
  end

  defp put_child(%__MODULE__{} = tabs, id, %Child{} = child),
    do: %{tabs | subagents: Map.put(tabs.subagents, id, child)}
end
