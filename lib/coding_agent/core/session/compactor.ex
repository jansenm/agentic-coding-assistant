defmodule CodingAgent.Core.Session.Compactor do
  @moduledoc """
  The compaction operation (slice 4b): trigger decision, summarize
  call, apply, backoff. The pure message plumbing lives in
  `CodingAgent.Core.Compaction`; this module owns the policy and the
  one provider call, so the session loop stays loop-shaped — it asks
  "should the context shrink?" and gets `{state, changed?}` back
  without knowing how.

  Policy (docs/source/explanation/memory.rst):

  - **Trigger**: the provider's own last-turn input_tokens against an
    ABSOLUTE threshold (`compaction_trigger_tokens`, default 180k —
    the opencode lesson: a big window with a %-trigger compacts far
    too late, and per-turn cost scales with context size). Chars are
    only the FIRST-TURN fallback (usage unknown); known-but-below
    usage NEVER compacts — the old chars fallback fired at ~20k
    tokens on fat contexts and stalled every turn behind a
    minutes-long summarize call (found live: a fresh review session
    hit compaction after a handful of file reads, then hung).
  - **The plan is decided ONCE** and its summary span passed through:
    re-planning with a different threshold (the old code compacted on
    tokens, then re-planned on chars) summarized a different span
    than the trigger decided on — or no span at all, which made the
    task exit abnormally.
  - **Every task exit is handled**: result, error, crash, budget
    timeout. Failure degrades (keep the full context, back off),
    never errors the turn. Found live twice: an unhandled
    `{:exit, _}` from `Task.yield/2` crashed the session mid-turn
    with a CaseClauseError, and an unbounded summary hung past
    2 minutes (receive_timeout only covers INACTIVITY — hence the
    hard wall-clock budget).

  The compacted state is returned with `changed?: true`; the caller
  persists it before the next provider call — a crash right after
  compaction must not resurrect the fat context.
  """

  alias CodingAgent.Core.Compaction
  alias CodingAgent.Core.Session.{Request, State, Usage}
  alias ReqLLM.Context

  require Logger

  # Hard wall-clock bound on the summarize call: receive_timeout only
  # covers INACTIVITY, and a slow cloud model can hold the summary
  # call open indefinitely (found live — compaction hung past 2
  # minutes mid-turn). After the wall: give up, keep the full
  # context, back off. The defaults live in Core.Config; env-overridable
  # so tests can exercise the budget branch in milliseconds.
  #
  # The inactivity bound is shorter than the wall clock so a HUNG
  # provider ends the task with a proper {:error, _} long before the
  # wall; a slow-but-alive model stays under it and hits the wall
  # instead (that is the budget's job).

  # Consecutive turn-skips after a failed summarize (the summary call
  # is minutes of cloud time; a per-turn retry is 2+ min of dead
  # silence before every real turn).
  @consecutive_failures 3

  @warn_fraction 0.8

  @typedoc "Injected summarizer: session state and rendered old span in, summary text out."
  @type summarize_fn :: (State.t(), String.t() -> {:ok, String.t()} | {:error, term()})

  @doc """
  Runs the compaction check before an LLM call. Returns `{state,
  changed?}` — the caller persists when `changed?` is true.

  The summarizer is injectable (tests are LLM-free); the default is
  `summarize/2`, bounded by `:compaction_inactivity_ms` (inactivity)
  and `:compaction_wall_clock_ms` (wall clock).
  """
  @spec maybe_compact(State.t(), summarize_fn() | nil) :: {State.t(), boolean()}
  def maybe_compact(state, summarize_fn \\ nil)

  def maybe_compact(%State{compaction_backoff: backoff} = state, _summarize_fn)
      when backoff > 0 do
    # compaction failed recently — skip and count down. (Countdown
    # ticks are not persisted; the turn boundary saves whatever state
    # the turn ends in.)
    {%{state | compaction_backoff: backoff - 1}, false}
  end

  # structural guard for the tests-are-LLM-free discipline: the
  # summarizer IS a provider call. (The loud backstop lives in
  # Session.continue_loop/1 — this is the quiet structural skip.)
  def maybe_compact(%State{test_mode: true} = state, _summarize_fn), do: {state, false}

  def maybe_compact(%State{} = state, nil), do: maybe_compact(state, &summarize/2)

  def maybe_compact(%State{} = state, summarize_fn) do
    trigger = trigger()

    case decide(state, trigger) do
      {:ok, {old, _keep}} -> compact(state, old, summarize_fn)
      :none -> warn_approaching(state, trigger)
    end
  end

  @doc """
  Pure trigger decision: `:none`, or `{:ok, {summary_span, keep_span}}`.
  Known usage below the trigger NEVER compacts (the chars fallback
  fired at ~20k tokens and stalled every turn — found live); unknown
  usage (first turn, `last_input_tokens: 0`) falls back to the
  chars-based plan. Public: tests are LLM-free.
  """
  @spec decide(State.t(), pos_integer()) :: :none | {:ok, {list(), list()}}
  def decide(%State{} = state, trigger) do
    last_in = Usage.last_input_tokens(state.usage)

    cond do
      last_in >= trigger ->
        # provider-reported input tokens are ground truth (the token
        # path compacts exactly when the real context is past trigger)
        to_plan(Compaction.plan_tokens(state.context, last_in, trigger))

      # usage is genuinely unknown (first turn): conservative chars heuristic
      last_in == 0 ->
        to_plan(Compaction.plan(state.context))

      true ->
        :none
    end
  end

  defp to_plan(:none), do: :none
  defp to_plan({:ok, old, keep}), do: {:ok, {old, keep}}

  @doc """
  Warns once at 80% of the trigger so compaction is never a silent
  surprise (the opencode lesson: users trained on "it will auto
  compact" stop watching and then burn quota). Returns `{state,
  warned?}`. Public: tests are LLM-free.
  """
  @spec warn_approaching(State.t(), pos_integer()) :: {State.t(), boolean()}
  def warn_approaching(%State{} = state, trigger) do
    last_in = Usage.last_input_tokens(state.usage)
    warn_at = trunc(trigger * @warn_fraction)

    if last_in >= warn_at and not state.compaction_warned do
      state = %{state | compaction_warned: true}

      broadcast(
        state,
        {:info,
         "· context at #{div(last_in, 1000)}k tokens — compaction at #{div(trigger, 1000)}k will summarize older messages"}
      )

      {state, true}
    else
      {state, false}
    end
  end

  # -- The summarize operation -------------------------------------------------

  # The summarize call is a slow NON-streaming round trip: tell the UI
  # NOW, otherwise the user stares at a running dot with no reasoning,
  # no answer, no clue (found live — 2+ min of silence).
  # The summarize task runs under a Task.Supervisor with async_nolink:
  # the task executes third-party code (req_llm, provider adapters), and
  # a plain Task.async/1 LINKS the task to the session — a crash inside
  # the provider stack would then kill the whole session process before
  # Task.yield/2 could ever observe it (verified: a raising summarizer
  # takes the linked caller down; the {:exit, _} clause never fires).
  # With the supervisor the crash is contained there and surfaces HERE
  # as {:exit, reason} — one more failure mode that degrades instead of
  # killing the session. The supervisor lives in the application tree;
  # tests without the tree get a lazy one (same pattern as the
  # interrupt ETS table).
  defp compact(state, old, summarize_fn) do
    Logger.debug("compacting context (#{Compaction.total_chars(old)} chars)")
    broadcast(state, {:info, "· compacting context (this can take a while)…"})

    task =
      Task.Supervisor.async_nolink(task_supervisor(), fn ->
        summarize_fn.(state, Compaction.render(old))
      end)

    case Task.yield(task, wall_clock()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, summary_text}} ->
        apply_summary(state, summary_text)

      {:ok, {:error, reason}} ->
        compaction_failed(state, reason)

      # An abnormal task exit must degrade like any other failure — an
      # unhandled {:exit, _} here was a CaseClauseError that killed the
      # session mid-turn (found live). With async_nolink this is also
      # the path a provider-stack crash takes (see compact/3).
      {:exit, reason} ->
        compaction_failed(state, {:summarize_task_exit, reason})

      # a well-behaved summarizer only ever returns the two tuples above
      {:ok, other} ->
        compaction_failed(state, {:unexpected_summarizer_result, other})

      # wall-clock budget exceeded (Task.shutdown(:brutal_kill) => nil):
      # keep the full context, back off
      nil ->
        Logger.warning(
          "compaction summarize exceeded #{div(wall_clock(), 1000)}s, keeping full context"
        )

        broadcast(
          state,
          {:info, "· compaction timed out; skipping the next #{@consecutive_failures} turns"}
        )

        {%{state | compaction_backoff: @consecutive_failures}, false}
    end
  end

  defp apply_summary(state, summary_text) do
    context = Compaction.apply(state.context, summary_text)

    # compaction_warned resets with the new context: the NEXT approach
    # to the trigger deserves its warning again (warn-once per approach)
    state = %{state | context: context, compaction_backoff: 0, compaction_warned: false}
    broadcast(state, {:context_compacted, Compaction.keep_recent()})
    {state, true}
  end

  defp compaction_failed(state, reason) do
    Logger.warning("compaction failed, keeping full context: #{inspect(reason)}")

    broadcast(
      state,
      {:info,
       "· compaction failed (#{inspect(reason, printable_limit: 40)}); skipping the next #{@consecutive_failures} turns"}
    )

    {%{state | compaction_backoff: @consecutive_failures}, false}
  end

  # The default summarizer. Sees the OLD span only (the keep span is
  # excluded — the model would otherwise copy it into the summary),
  # rendered by `Compaction.render/1`. Everything is CONTAINED: a
  # raise, exit or throw inside req_llm or a provider adapter must
  # surface as {:error, _}, never as a linked crash — under the
  # supervisor (compact/3) an unwrapped crash would only surface as
  # {:exit, _}, and containment here keeps the failure legible
  # (reason inspectable, classified, broadcast) instead of a bare
  # process exit.
  @doc false
  @spec summarize(State.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def summarize(state, old_span_text) do
    with {:ok, model_input, base_opts} <-
           Request.build(State.effective_model(state), state.provider_config),
         {:ok, response} <-
           ReqLLM.generate_text(
             model_input,
             summary_context(old_span_text),
             summarize_opts(base_opts)
           ) do
      case ReqLLM.Response.text(response) do
        text when is_binary(text) and text != "" -> {:ok, text}
        _ -> {:error, :empty_summary}
      end
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_summarizer_result, other}}
    end
  rescue
    e -> {:error, {:summarize_exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # GLM on an 80K-char context takes minutes; without an inactivity cap
  # a hung summary stalls every turn's start (found live). Shorter than
  # the wall clock so a hung provider becomes a proper error result.
  #
  # `Request.build/2`'s opts (base_url for indirected providers — the
  # ollama-cloud case) MUST be kept: the old code discarded them, so a
  # summary call went to the wrong (default) endpoint while the turn
  # loop used the configured one.
  defp summarize_opts(base_opts) do
    Keyword.put(base_opts, :receive_timeout, inactivity())
  end

  defp summary_context(old_span_text) do
    Context.new()
    |> Context.append(ReqLLM.Context.system(summary_prompt()))
    |> Context.append(ReqLLM.Context.user(old_span_text))
  end

  defp summary_prompt do
    "Summarize the following (possibly interrupted) coding-agent " <>
      "conversation for later reuse. Preserve: the user's goals, " <>
      "decisions made, files touched, commands run and their " <>
      "outcomes, and anything explicitly promised. Be factual and " <>
      "complete; omit small talk."
  end

  # -- Configuration ------------------------------------------------------------

  # Absolute threshold from config — visible in the sidebar, predictable
  # (the opencode lesson: compaction must be a known quantity, not a
  # silent %-of-window surprise). Public: the sidebar renders the same
  # number, and there must be ONE reader of the config key.
  @spec trigger() :: pos_integer()
  def trigger, do: CodingAgent.Core.Config.compaction_trigger_tokens()

  @doc """
  The token count at which the approaching-compaction warning fires
  (`#{@warn_fraction}` of the trigger). Public so the sidebar and
  `warn_approaching/2` cannot drift apart on the fraction.
  """
  @spec warn_threshold() :: non_neg_integer()
  def warn_threshold, do: trunc(trigger() * @warn_fraction)

  defp wall_clock, do: CodingAgent.Core.Config.compaction_wall_clock_ms()
  defp inactivity, do: CodingAgent.Core.Config.compaction_inactivity_ms()

  # The summarize task must never be linked to the session (see
  # compact/3): the supervisor is a permanent child of the application
  # tree, created lazily when the tree is absent (bare tests).
  defp task_supervisor do
    case Process.whereis(Compactor.TaskSupervisor) do
      nil ->
        case Task.Supervisor.start_link(name: Compactor.TaskSupervisor) do
          {:ok, _pid} -> Compactor.TaskSupervisor
          {:error, {:already_started, _pid}} -> Compactor.TaskSupervisor
        end

      pid when is_pid(pid) ->
        pid
    end
  end

  # Broadcast to the session's event subscribers — same channel as the
  # session loop; compaction progress must be visible while it runs.
  #
  # Also record the display view (ADR 020): compaction notes and the
  # "context compacted" marker are part of what the user SAW, and the
  # display view is the immutable record compaction must never touch.
  # (The agent view is rewritten by apply_summary; this is the other
  # view, and it only grows.)
  defp broadcast(state, event) do
    case event do
      {:info, text} ->
        _ = CodingAgent.Core.Session.Store.append_display(state.id, :info, text)

      {:context_compacted, _keep} ->
        _ = CodingAgent.Core.Session.Store.append_display(state.id, :info, "· context compacted")

      _ ->
        :ok
    end

    CodingAgent.Core.Events.publish(state.id, event)
  end
end
