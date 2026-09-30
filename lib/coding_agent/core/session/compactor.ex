defmodule CodingAgent.Core.Session.Compactor do
  @moduledoc """
  The compaction operation (slice 4b, two-limit policy ADR 037): trigger
  decision, summarize call, apply, backoff. The pure message plumbing
  lives in `CodingAgent.Core.Compaction`; this module owns the policy and
  the one provider call, so the session loop stays loop-shaped — it asks
  "should the context shrink?" and gets `{state, changed?}` back without
  knowing how.

  Policy (docs/source/explanation/memory.rst, ADR 037):

  - **Two limits derived from the model window.** A **soft** limit
    (`round(window * compaction_soft_ratio)`, default 50%) fires while
    the session is IDLE: after a turn ends the session summarizes down in
    the background, so the next prompt does not pay the latency. A
    **hard** limit (`window - compaction_hard_reserve_tokens`, default
    64k reserve) fires PRE-CALL, busy or not: the reserve is one maximum
    tool result plus response headroom, so a single big result cannot
    overflow the window mid-turn. If the hard limit is at or below the
    soft one (a very small window), soft collapses to hard.
  - **Projected size, not the stale count.** The decision uses
    `max(last_input_tokens, chars/4)`: the last provider count is ground
    truth but does not include tool results produced after that call —
    the bulk of the growth — so a big `read_file`/`shell` result could
    cross the window between the check and the send (found live).
  - **The plan is decided ONCE** and its summary span passed through:
    re-planning with a different threshold summarized a different span
    than the trigger decided on — or none, which made the task exit
    abnormally.
  - **Every task exit is handled**: result, error, crash, budget
    timeout. Failure degrades. On a HARD failure the session no longer
    keeps a full, over-window context: it falls back to a deterministic
    trim of the oldest complete exchanges (loud, and lossy by design —
    proceeding over the window is the one outcome the reserve prevents).
  - **The idle pass is fingerprint-guarded**: if the context changed
    while the summarize task ran (a new turn started), the summary is
    discarded, never applied to a context it no longer matches.

  The compacted state is returned with `changed?: true`; the caller
  persists it before the next provider call — a crash right after
  compaction must not resurrect the fat context.
  """

  alias CodingAgent.Core.Compaction
  alias CodingAgent.Core.Config
  alias CodingAgent.Core.Session.{Request, State, Usage}
  alias ReqLLM.Context

  require Logger

  # Consecutive turn-skips after a failed summarize (the summary call
  # is minutes of cloud time; a per-turn retry is 2+ min of dead
  # silence before every real turn).
  @consecutive_failures 3

  @warn_fraction 0.8

  @typedoc "Injected summarizer: session state and rendered old span in, summary text out."
  @type summarize_fn :: (State.t(), String.t() -> {:ok, String.t()} | {:error, term()})

  @doc """
  The HARD, pre-call compaction check (ADR 037). Runs before an LLM call,
  busy or not. Returns `{state, changed?}` — the caller persists when
  `changed?` is true.

  On summarize failure this keeps the context and backs off, EXCEPT at
  the hard limit, where it degrades to a deterministic trim
  (`trim_hard/1`) rather than send an over-window request.
  """
  @spec maybe_compact(State.t(), summarize_fn() | nil) :: {State.t(), boolean()}
  def maybe_compact(state, summarize_fn \\ nil)

  # structural guard for the tests-are-LLM-free discipline: the
  # summarizer IS a provider call. Checked BEFORE the backoff clause: the
  # backoff path can now trim the context (a hard-limit mutation), and a
  # test-mode session must stay structurally inert.
  def maybe_compact(%State{test_mode: true} = state, _summarize_fn), do: {state, false}

  def maybe_compact(%State{compaction_backoff: backoff} = state, _summarize_fn)
      when backoff > 0 do
    # compaction failed recently — skip and count down. The hard
    # limit is a safety net, so a backoff must still not let the
    # context overflow: if the projected size is past the hard limit,
    # trim deterministically instead of skipping.
    if projected_tokens(state) >= hard_limit(state) do
      trim_hard(state)
    else
      {%{state | compaction_backoff: backoff - 1}, false}
    end
  end

  def maybe_compact(%State{} = state, nil), do: maybe_compact(state, &summarize/2)

  def maybe_compact(%State{} = state, summarize_fn) do
    limit = hard_limit(state)

    case decide(state, limit) do
      {:ok, {old, _keep}} -> compact(state, old, summarize_fn, :hard)
      :none -> warn_approaching(state)
    end
  end

  @doc """
  The SOFT, idle compaction check (ADR 037). Intended to run in a
  background task after a turn ends (the caller owns the task and the
  fingerprint guard). Uses the soft limit; on failure it simply backs
  off — the soft pass is an optimization, not a gate.
  """
  @spec maybe_compact_idle(State.t(), summarize_fn() | nil) :: {State.t(), boolean()}
  def maybe_compact_idle(state, summarize_fn \\ nil)

  def maybe_compact_idle(%State{test_mode: true} = state, _summarize_fn), do: {state, false}

  def maybe_compact_idle(%State{compaction_backoff: backoff} = state, _summarize_fn)
      when backoff > 0 do
    {%{state | compaction_backoff: backoff - 1}, false}
  end

  def maybe_compact_idle(%State{} = state, nil), do: maybe_compact_idle(state, &summarize/2)

  def maybe_compact_idle(%State{} = state, summarize_fn) do
    limit = soft_limit(state)

    case decide(state, limit) do
      {:ok, {old, _keep}} -> compact(state, old, summarize_fn, :soft)
      :none -> {state, false}
    end
  end

  @doc """
  Whether there is a span worth compacting at all (a manual `/compact`
  and the trigger decision share this). `false` when the context is too
  short for `Compaction.split/1` to find a whole old exchange, or in
  test_mode (the summary IS a provider call). Public: tests are LLM-free.
  """
  @spec can_compact?(State.t()) :: boolean()
  def can_compact?(%State{test_mode: true}), do: false

  def can_compact?(%State{} = state) do
    match?({:ok, _old, _keep}, Compaction.split(state.context.messages))
  end

  @doc """
  A MANUAL compaction (`/compact`, ctrl-x c): summarize the older span
  NOW, ignoring the soft/hard limits — the human asked for it, so "is it
  over a threshold?" is the wrong question. Returns `{state, changed?}`
  like the other passes; `:none` (nothing worth compacting) leaves the
  state untouched. The caller runs this in a background task (the summary
  is a slow provider call), so it must not block the session.
  """
  @spec compact_now(State.t(), summarize_fn() | nil) :: {State.t(), boolean()}
  def compact_now(state, summarize_fn \\ nil)

  def compact_now(%State{test_mode: true} = state, _summarize_fn), do: {state, false}

  def compact_now(%State{} = state, nil), do: compact_now(state, &summarize/2)

  def compact_now(%State{} = state, summarize_fn) do
    case Compaction.split(state.context.messages) do
      {:ok, old, _keep} -> compact(state, old, summarize_fn, :manual)
      :none -> {state, false}
    end
  end

  @doc """
  Pure trigger decision: `:none`, or `{:ok, {summary_span, keep_span}}`.
  Uses the PROJECTED size (see the moduledoc); genuinely unknown usage
  (first turn, `last_input_tokens: 0`) falls back to the chars-based
  plan. Known-but-below usage NEVER compacts. Public: tests are
  LLM-free.
  """
  @spec decide(State.t(), pos_integer()) :: :none | {:ok, {list(), list()}}
  def decide(%State{} = state, limit) do
    last_in = Usage.last_input_tokens(state.usage)

    cond do
      last_in == 0 ->
        # usage is genuinely unknown (first turn): conservative chars heuristic
        to_plan(Compaction.plan(state.context))

      projected_tokens(state) >= limit ->
        to_plan(Compaction.plan_tokens(state.context, projected_tokens(state), limit))

      true ->
        :none
    end
  end

  defp to_plan(:none), do: :none
  defp to_plan({:ok, old, keep}), do: {:ok, {old, keep}}

  # The size compaction decides on: the provider's own last-turn input
  # count (ground truth) or a chars/4 estimate of the CURRENT context,
  # whichever is larger. The count lags the context by the tool results
  # produced after the last call, so the max closes that gap (ADR 037).
  @doc false
  @spec projected_tokens(State.t()) :: non_neg_integer()
  def projected_tokens(%State{usage: usage, context: %Context{messages: msgs}}) do
    max(Usage.last_input_tokens(usage), div(Compaction.total_chars(msgs), 4))
  end

  def projected_tokens(%State{usage: usage}), do: Usage.last_input_tokens(usage)

  @doc """
  Warns once at 80% of the soft limit so compaction is never a silent
  surprise (the opencode lesson: users trained on "it will auto compact"
  stop watching and then burn quota). Returns `{state, warned?}`.
  Public: tests are LLM-free.
  """
  @spec warn_approaching(State.t()) :: {State.t(), boolean()}
  def warn_approaching(%State{} = state) do
    current = projected_tokens(state)
    warn_at = warn_threshold(state)

    if current >= warn_at and not state.compaction_warned do
      state = %{state | compaction_warned: true}

      broadcast(
        state,
        {:info,
         "· context at #{div(current, 1000)}k tokens — compaction at #{div(soft_limit(state), 1000)}k will summarize older messages"}
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
  defp compact(state, old, summarize_fn, kind) do
    span = Compaction.render(old)

    # An empty rendered span means there is nothing NEW to summarize: the
    # only "old" message is the prior summary itself, which `render/1`
    # skips by design (review N16). Calling the provider would ask it to
    # summarize nothing and then REPLACE the prior summary with the
    # answer — losing facts for no gain, plus a needless non-streamed call.
    # The prior summary already IS the compacted state, so this is a no-op.
    if String.trim(span) == "" do
      {state, false}
    else
      do_compact(state, span, summarize_fn, kind)
    end
  end

  defp do_compact(state, span, summarize_fn, kind) do
    Logger.debug("compacting context (#{byte_size(span)} chars rendered)")
    broadcast(state, {:info, "· compacting context (this can take a while)…"})

    task =
      Task.Supervisor.async_nolink(task_supervisor(), fn ->
        summarize_fn.(state, span)
      end)

    case Task.yield(task, wall_clock()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, summary_text}} ->
        apply_summary(state, summary_text)

      {:ok, {:error, reason}} ->
        compaction_failed(state, reason, kind)

      {:exit, reason} ->
        compaction_failed(state, {:summarize_task_exit, reason}, kind)

      {:ok, other} ->
        compaction_failed(state, {:unexpected_summarizer_result, other}, kind)

      nil ->
        Logger.warning(
          "compaction summarize exceeded #{div(wall_clock(), 1000)}s, keeping full context"
        )

        compaction_failed(state, :wall_clock_exceeded, kind)
    end
  end

  defp apply_summary(state, summary_text) do
    context = Compaction.apply(state.context, summary_text)

    # compaction_warned resets with the new context: the NEXT approach
    # to the trigger deserves its warning again (warn-once per approach)
    state = %{state | context: context, compaction_backoff: 0, compaction_warned: false}
    state = note_shrunk_context(state)
    broadcast(state, {:context_compacted, Compaction.min_keep()})
    {state, true}
  end

  # `last_input_tokens` is the count the PROVIDER last saw, so after the
  # context shrinks it overstates the real size by the whole summarized
  # span. Left alone, the sidebar keeps showing the pre-compaction number
  # (found live: 400k after a successful compaction, until the next
  # provider turn happened to report a fresh count). Reset it to the
  # compacted context's own chars/4 estimate — the same fallback
  # `projected_tokens/1` uses — and broadcast, so the display, the next
  # trigger and the model-facing budget block all agree at once.
  defp note_shrunk_context(%State{usage: usage} = state) do
    estimate = div(Compaction.total_chars(state.context.messages), 4)
    usage = %{usage | last_input_tokens: estimate}
    broadcast(state, {:usage_updated, usage})
    %{state | usage: usage}
  end

  # A failure degrades. The soft pass simply backs off. The hard pass
  # must not leave an over-window context: when the projected size is
  # still past the hard limit, trim deterministically (loud).
  defp compaction_failed(state, reason, kind) do
    Logger.warning("compaction failed, keeping full context: #{inspect(reason)}")

    broadcast(
      state,
      {:info,
       "· compaction failed (#{inspect(reason, printable_limit: 40)}); skipping the next #{@consecutive_failures} turns"}
    )

    state = %{state | compaction_backoff: @consecutive_failures}

    if kind == :hard and projected_tokens(state) >= hard_limit(state) do
      trim_hard(state)
    else
      {state, false}
    end
  end

  # The deterministic hard-limit fallback: drop the oldest complete
  # exchanges (the system message is pinned) until the estimated size
  # is under the limit, with a loud note. Lossy by design — it is the
  # alternative to sending a request the provider would reject.
  @doc false
  @spec trim_hard(State.t()) :: {State.t(), boolean()}
  def trim_hard(%State{} = state) do
    limit = hard_limit(state)

    case Compaction.trim(state.context, limit) do
      {:ok, trimmed, dropped} ->
        Logger.warning("hard compaction limit: trimmed #{dropped} old messages keeping context")

        broadcast(
          state,
          {:info, "· context over the hard limit — trimmed #{dropped} old messages"}
        )

        state = note_shrunk_context(%{state | context: trimmed, compaction_warned: false})
        {state, true}

      :none ->
        # nothing left to trim (a huge single exchange): keep it and let
        # the provider answer — the reserve already bought the headroom.
        Logger.warning("hard compaction limit reached but nothing trimmable remains")
        {state, false}
    end
  end

  # The default summarizer. Sees the OLD span only (the keep span is
  # excluded — the model would otherwise copy it into the summary),
  # rendered by `Compaction.render/1`. Everything is CONTAINED: a
  # raise, exit or throw inside req_llm or a provider adapter must
  # surface as {:error, _}, never as a linked crash.
  @doc false
  @spec summarize(State.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def summarize(state, old_span_text) do
    prior = Compaction.prior_summary(state.context)

    with {:ok, model_input, base_opts} <-
           Request.build(State.effective_model(state), state.provider_config, state.scope_root),
         {:ok, response} <-
           ReqLLM.generate_text(
             model_input,
             summary_context(old_span_text, prior),
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
  # a hung summary stalls every turn's start (found live).
  #
  # `max_tokens` caps the summary OUTPUT (review N18). Without it a model
  # could return a very long summary; `Compaction.apply/2` then stores it
  # verbatim and the NEXT prompt pays for it — on a small window the
  # summary itself becomes the overflow. opencode uses the same guard
  # (SUMMARY_OUTPUT_TOKENS). The value is a generous ceiling, not a
  # target: the template asks for terse bullets. It also bounds the
  # carried-forward input, which accumulates across compactions.
  @summary_output_tokens 4_096

  defp summarize_opts(base_opts) do
    base_opts
    |> Keyword.put(:receive_timeout, inactivity())
    |> Keyword.put(:max_tokens, @summary_output_tokens)
  end

  defp summary_context(old_span_text, prior_summary) do
    # No system message: the summarizer is a one-shot text transform, and
    # the instruction is the request. The request TEXT (template +
    # rolling-summary rules) is built by `Compaction.summary_prompt/2` —
    # pure, and the place that wording is testable without a provider.
    Context.new()
    |> Context.append(
      ReqLLM.Context.user(Compaction.summary_prompt(old_span_text, prior_summary))
    )
  end

  # -- The two limits (ADR 037) -------------------------------------------------

  @doc """
  The model context window the session resolved (ADR 037), or a config
  fallback for a hand-built state. Public: the sidebar renders it.
  """
  @spec window(State.t()) :: pos_integer()
  def window(%State{context_window: window}) when is_integer(window), do: window

  def window(%State{} = state), do: limits(state) |> elem(0)

  @doc """
  The HARD limit: `window - reserve`, at least 1. Fires pre-call.
  """
  @spec hard_limit(State.t()) :: pos_integer()
  def hard_limit(%State{compaction_hard_limit: hard}) when is_integer(hard), do: hard
  def hard_limit(%State{} = state), do: limits(state) |> elem(2)

  @doc """
  The SOFT limit: `round(window * ratio)`, clamped to the hard limit so
  the order is never inverted on a small window. Fires while idle.
  """
  @spec soft_limit(State.t()) :: pos_integer()
  def soft_limit(%State{compaction_soft_limit: soft}) when is_integer(soft), do: soft
  def soft_limit(%State{} = state), do: limits(state) |> elem(1)

  @doc """
  The token count at which the approaching-compaction warning fires
  (`#{@warn_fraction}` of the soft limit). Public so the sidebar and
  `warn_approaching/1` cannot drift apart.
  """
  @spec warn_threshold(State.t()) :: non_neg_integer()
  def warn_threshold(%State{} = state), do: trunc(soft_limit(state) * @warn_fraction)

  # The one read of the window/limit policy for a state that did not
  # resolve it at init (a hand-built state in a test). The session
  # resolves and stores these, so production never re-reads config.
  defp limits(%State{} = state), do: Config.compaction_limits(state.scope_root, state.model)

  defp wall_clock, do: Config.compaction_wall_clock_ms()
  defp inactivity, do: Config.compaction_inactivity_ms()

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
  # session loop; compaction progress must be visible while it runs. Also
  # records the display view (ADR 020): compaction notes are what the
  # user SAW, and the display view is the immutable record.
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
