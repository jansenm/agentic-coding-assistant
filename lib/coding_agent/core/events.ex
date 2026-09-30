defmodule CodingAgent.Core.Events do
  @moduledoc """
  The session event vocabulary and its single publish point (ADR 008).

  A session broadcasts progress to whoever registered on
  `CodingAgent.EventRegistry` under `{:session_events, id}`. Before this
  module, five call sites each re-implemented the same
  `Registry.dispatch/3` + `send(pid, {:agent, event})` dance (the
  untagged shape of the time); a change to the delivery shape meant five
  edits.

  `publish/2` is the one writer. Subscribers receive `{:agent, id, event}`
  messages — the SOURCE session id rides along, because a TUI may
  subscribe to more than one session (a parent and its subagent children,
  ADR 018) and must route each event to the right view rather than
  blending a child's stream into the parent's transcript. The event terms
  are listed in `event/0` so the vocabulary is greppable and the UI/core
  contract is explicit.
  """

  @registry CodingAgent.EventRegistry
  @key :session_events

  @typedoc """
  Every event a session publishes. Kept as documentation of the wire
  contract between a session and its subscribers.

    * `{:llm_deltas, text}` / `{:reasoning_deltas, text}` — streaming deltas
    * `{:llm_message, text}` — the full assistant answer for a turn
    * `{:turn_started, agent_name | nil}` — the agent handling the turn
    * `{:status_changed, status}` / `{:status_changed, status, detail}`
    * `{:status_changed, :budget_reached, %{budget: n}}` — the tool-round
      budget was reached and the driver is asked to continue or stop
      (ADR 025; only an interactive session emits this)
    * `{:status_changed, :doom_reached, %{tool: name}}` — a repeated call
      was detected and the driver is asked to continue or reject
      (ADR 026; interactive only)
    * `{:status_changed, :question_asked, %{questions: [...]}}` — the
      model asked the human a question and the driver must answer
      (ADR 027; interactive only)
    * `{:subagent_started, child_id, agent_name, model}` — a `task` call
      started a child session (ADR 017/018; published on the PARENT's
      channel). The child's own events go to its own id; the TUI may
      subscribe to `child_id` for a tab and must unsubscribe at
      `:subagent_finished`.
    * `{:subagent_finished, child_id, outcome}` — the child ended
      (`:ok` or `:error`); only its summary is in the parent's context
    * `{:tool_started, name}` — one tool call about to run (before result)
    * `{:tool_executed, name, content, args}` — one finished tool result
      with the arguments it was called with (the display view records
      them, so an export can say *what* a tool was asked to do)
    * `{:usage_updated, usage}` — cumulative token/cost accounting
    * `{:info, text}` — a dim one-line note (compaction, notices)
    * `{:context_compacted, min_keep}` — a compaction replaced the old
      span with a summary; the payload is how many recent messages were
      kept verbatim
    * `{:provider_status, :up}` / `{:provider_status, :down, reason}`
    * `{:context_window, window, soft, hard}` — the model catalog finished
      loading (ADR 039) and the session re-resolved its compaction window
      against it (the mount may have raced the background load and used
      the fallback). Subscribers that mirror the window re-read it.
  """
  @type event :: term()

  @doc """
  Publishes `event` to every subscriber of `session_id`. The delivered
  message is `{:agent, session_id, event}`: the id is the SOURCE, so a
  multi-session subscriber (the TUI with subagent tabs, ADR 018) can route
  it. A single-session subscriber still finds the event in the third
  element.
  """
  @spec publish(String.t(), event()) :: :ok
  def publish(session_id, event) do
    Registry.dispatch(@registry, {@key, session_id}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:agent, session_id, event})
    end)

    :ok
  end

  @doc "The registry key sessions publish under (for `Session.subscribe/1`)."
  @spec key() :: :session_events
  def key, do: @key
end
