defmodule CodingAgent.Core.Compaction do
  @moduledoc """
  Pure message plumbing for working-context compaction (slice 4b):
  the short-term memory tier.

  The message history sent to the LLM grows fast (tool outputs are the
  bulk) and, unchecked, reaches the model's window mid-task. Compaction
  summarizes the *old* part of the conversation and keeps the recent
  tail verbatim — the model keeps working with a compact summary plus
  fresh detail, instead of failing on window overflow.

  This module is the data layer: plan (which span), apply (replace the
  span with the summary), render (span → text for the summarizer). The
  POLICY and the provider call live in
  `CodingAgent.Core.Session.Compactor` — trigger thresholds, budgets,
  backoff and broadcasting are that module's job, not ours.

  Design (docs/source/explanation/memory.rst):

  - **Trigger**: the two limits (soft/hard) live in the Compactor; this
    module only turns a decided token threshold into a span plan.
  - **The system message is never summarized.** It is the framework
    prompt (ADR 024) and the agent body (ADR 017); losing it blinded the
    agent after the first compaction (found live: a compacted session
    had zero system messages, so `Prompt.with_environment/3` and
    `with_todos/2` silently no-op'd — the model ran on a summary and a
    bare tail). `split/1` keeps message 0 when it is a system message.
  - **Boundary-safe tail**: the keep span starts at a complete exchange.
    Cutting at a message count could put a `:tool` result in the tail
    whose declaring assistant call was summarized away, or vice versa
    (found live: the kept tail began with a `:tool` message).
  - **Fact-carrying summary**: `render/1` keeps tool NAMES and call
    arguments, not just text parts. The old render dropped `tool_calls`
    (assistant calls are text-empty) and `msg.name`, so the summary could
    not say *which* file was read or *which* command ran — the resumed
    agent re-derived work it had already done (found live: 29 rewrites
    of one document).
  - **Dual view note (v1)**: the CLI transcript is ephemeral, so v1
    compaction rewrites the agent view only. When the dual-view
    transcript lands (phase 5), the display view is the immutable
    record this operation must never touch.
  """

  alias CodingAgent.Core.ToolCall
  alias ReqLLM.Context

  # A complete exchange is a user message, or an assistant message plus
  # the tool results that answer it. The old fixed "last 6 messages"
  # boundary could split such a pair; the tail is now chosen by complete
  # exchanges, and @min_keep bounds how little survives.
  @min_keep 6

  # A result longer than this is truncated in the rendered span (the
  # marker is explicit, never a silent drop); the summarizer does not
  # need a full 200 KB tool dump to record "ran the suite, 922 passed".
  @render_result_chars 2_000

  # The summarizer input is bounded: one giant old span (measured at
  # 193 messages / ~42k tokens) became a minutes-long non-streaming
  # call. A hard cap keeps the summarize call predictable; the marker
  # makes the truncation honest.
  @max_summary_input_chars 300_000

  @doc "Minimum number of recent messages a compaction keeps verbatim."
  @spec min_keep() :: pos_integer()
  def min_keep, do: @min_keep

  # The stable prefix every synthetic summary message carries. It is the
  # marker that identifies a prior summary, so the next compaction can
  # CARRY IT FORWARD instead of re-deriving from the span alone (a fact
  # recorded in an early summary must survive the third compaction, not
  # only the one that first saw it). Kept as a literal so both the writer
  # (`apply/2`) and the reader (`prior_summary/1`) cannot drift.
  @summary_prefix "[Conversation summary — earlier messages were compacted"

  @doc "Whether a message is a synthetic compaction summary."
  @spec summary_message?(ReqLLM.Message.t()) :: boolean()
  def summary_message?(%ReqLLM.Message{role: :user} = msg) do
    # A summary is always our synthetic user message with the marker
    # prefix; nothing the model or user writes starts with it in practice.
    # `trim_leading` because a hand-edited or re-serialized store could
    # prepend whitespace — an unrecognized summary would then be
    # re-summarized as new material, the exact thing the marker prevents
    # (review N21).
    msg |> text_of() |> String.trim_leading() |> String.starts_with?(@summary_prefix)
  end

  def summary_message?(_), do: false

  @doc """
  The most recent summary text already in `context`, or `nil`. This is
  the "prior summary" a rolling compaction folds the new span into, so
  facts carried by an earlier summary are not lost when the span that
  first produced them is summarized again.
  """
  @spec prior_summary(Context.t() | [ReqLLM.Message.t()]) :: String.t() | nil
  def prior_summary(%Context{messages: msgs}), do: prior_summary(msgs)

  def prior_summary(msgs) when is_list(msgs) do
    msgs
    |> Enum.filter(&summary_message?/1)
    |> List.last()
    |> case do
      nil -> nil
      msg -> strip_summary_prefix(text_of(msg))
    end
  end

  @doc """
  The first-turn fallback plan (no usage data yet): chars-based, `:none`
  when below `trigger_chars`, otherwise `{:ok, summary_span,
  keep_span}`. The session-level decision (`Session.Compactor.decide/2`)
  only reaches this when usage is genuinely unknown.
  """
  @spec plan(Context.t()) :: :none | {:ok, summary_span :: list(), keep_span :: list()}
  def plan(%Context{messages: msgs}) do
    if span_chars(msgs) < trigger_chars() do
      :none
    else
      split(msgs)
    end
  end

  @doc """
  Token-based trigger: compact when the last observed input_tokens
  cross the decided threshold (`trigger_tokens`). `last_input_tokens:
  0` (no usage data yet) never triggers — the caller falls back to
  the chars-based plan.
  """
  @spec plan_tokens(Context.t(), non_neg_integer(), pos_integer()) ::
          :none | {:ok, summary_span :: list(), keep_span :: list()}
  def plan_tokens(%Context{messages: msgs}, last_input_tokens, trigger_tokens) do
    if last_input_tokens >= trigger_tokens do
      split(msgs)
    else
      :none
    end
  end

  @doc """
  Splits a message list into the span to summarize and the tail to keep.

  Three rules, each a live-found bug:

    * the **system message** (index 0, when present) is never summarized
      — it is the framework/agent prompt, not conversation; it is also
      excluded from `summary_span` so the summarizer is not fed the
      prompt it would only re-state;
    * the tail starts at a **complete exchange** boundary: never between
      an assistant call and its tool results, and never on a bare tool
      result whose declaring assistant message would be summarized;
    * at least `min_keep/0` messages survive when the context is large
      enough to compact at all.

  Returns `:none` when there is nothing worth compacting.
  """
  @spec split(list()) :: :none | {:ok, summary_span :: list(), keep_span :: list()}
  def split(msgs) do
    {_pinned, convo} = take_pinned(msgs)
    boundary = keep_start(convo)

    cond do
      convo == [] ->
        :none

      boundary <= 0 ->
        # everything is the tail (nothing old enough to summarize)
        :none

      true ->
        {old, keep} = Enum.split(convo, boundary)
        {:ok, old, keep}
    end
  end

  # The pinned HEAD of the context: the system message (never summarized)
  # and, if present, the synthetic summary that `apply/2` places directly
  # after it. Both belong to the head, not the conversation:
  #
  #   * the system message is the framework/agent prompt — nobody
  #     summarizes it;
  #   * the summary is already the compacted state. Excluding it here (not
  #     just from `render/1`) is what makes the rolling model correct
  #     (review N16): otherwise `split/1` could pick a span consisting of
  #     nothing but the summary, `render/1` would empty it, and a provider
  #     call would replace the summary with a summary of nothing. It also
  #     keeps the summary pinned through `trim/1` (review N20b), so the
  #     last-resort trim can no longer eat it.
  #
  # A context without a system message (a bare test context) and without a
  # summary has no prefix.
  defp take_pinned(msgs) do
    {system, rest} = take_system(msgs)
    {summary, rest} = take_summary(rest)
    {system ++ summary, rest}
  end

  defp take_system([%ReqLLM.Message{role: :system} = sys | rest]), do: {[sys], rest}
  defp take_system(msgs), do: {[], msgs}

  defp take_summary([msg | rest]) do
    if summary_message?(msg), do: {[msg], rest}, else: {[], [msg | rest]}
  end

  defp take_summary([]), do: {[], []}

  # The index into `convo` where the kept tail begins, chosen so the
  # tail is a whole number of exchanges and holds at least @min_keep
  # messages when possible.
  #
  # The default cut keeps the last @min_keep messages; it is then
  # snapped BACKWARD to the nearest exchange head (a :user message, or
  # an :assistant message whose tool results follow). Backward — not
  # forward — so the tail can never become empty and the kept exchange
  # is always whole: a bare :tool result at the cut belongs to an
  # assistant call that must stay with it.
  defp keep_start(convo) do
    n = length(convo)

    if n <= @min_keep do
      0
    else
      snap_back(convo, n - @min_keep)
    end
  end

  defp snap_back(_convo, 0), do: 0

  defp snap_back(convo, idx) do
    case exchange_head(Enum.at(convo, idx)) do
      {:user, _} -> idx
      {:assistant, _} -> idx
      :other -> snap_back(convo, idx - 1)
    end
  end

  defp exchange_head(%ReqLLM.Message{role: :user} = m), do: {:user, m}
  defp exchange_head(%ReqLLM.Message{role: :assistant} = m), do: {:assistant, m}
  defp exchange_head(_), do: :other

  @doc """
  Applies a summary: replaces the summarized span with one synthetic
  user message carrying the summary, keeping the pinned system message
  and the tail. Returns the new context (or the original when there is
  nothing to compact).
  """
  @spec apply(Context.t(), summary_text :: String.t()) :: Context.t()
  def apply(%Context{messages: msgs} = ctx, summary_text) do
    {system, convo} = take_system(msgs)
    boundary = keep_start(convo)

    if convo == [] or boundary <= 0 do
      ctx
    else
      {_old, keep} = Enum.split(convo, boundary)

      summary_msg = %ReqLLM.Message{
        role: :user,
        content: [
          ReqLLM.Message.ContentPart.text(compact_summary_text(bound_summary(summary_text)))
        ]
      }

      %Context{ctx | messages: system ++ [summary_msg | keep]}
    end
  end

  # A ceiling on the APPLIED summary (review N18). The provider is asked
  # for at most ~4k tokens (`Compactor.summarize_opts/1`), but a provider
  # that ignores `max_tokens` must not be able to store a summary larger
  # than the window it replaces: the summary rides every later prompt, so
  # an unbounded one becomes the overflow. Generous relative to the
  # 4k-token target (~24k chars at 4/ch) and only trims the pathological
  # case, with an honest marker.
  @max_summary_chars 24_000

  defp bound_summary(text) when byte_size(text) <= @max_summary_chars, do: text

  defp bound_summary(text) do
    String.slice(text, 0, @max_summary_chars) <>
      "\n\n[... summary truncated: #{byte_size(text)} chars total ...]"
  end

  @doc """
  Renders the summary span as one text block for the summarizer model —
  the only place message text is flattened for an LLM call. Tool calls
  and their arguments, and tool-result names, are included so the
  summary can preserve *what was done*, not just prose. The result is
  bounded by `@max_summary_input_chars`, with an explicit marker.

  A prior summary message is SKIPPED: it is carried forward separately
  (`prior_summary/1`) and re-rendering it as conversation would duplicate
  it and let the model summarize its own prior summary as if it were new
  material.
  """
  @spec render(list()) :: String.t()
  def render(msgs) do
    rendered =
      msgs
      |> Enum.reject(&summary_message?/1)
      |> Enum.map_join("\n\n", &render_message/1)

    bound_input(rendered)
  end

  @doc """
  The summarizer request text for a span, given the prior summary (or
  `nil` on the first compaction). Two shapes:

    * **first** — fill the fixed template from the span alone;
    * **rolling** — fold the new span into `prior_summary`, which is
      discarded after ("anything you do not carry into the new summary is
      lost"), so a fact recorded in an early summary survives the third
      compaction instead of being re-derived from the span each time.

  The template enumerates the fact categories (objective, decisions,
  work state, next move, files) so none is silently dropped, and it is
  the SAME structure every time, so a resumed agent reads one stable
  shape. Wording adapted from opencode (MIT, 2026-09-30; see
  `docs/source/explanation/compaction-strategies`); the identity is ours.
  """
  @spec summary_prompt(String.t(), String.t() | nil) :: String.t()
  def summary_prompt(span, prior) do
    conversation =
      "Here is the conversation so far:\n\n<conversation>\n#{span}\n</conversation>"

    case prior do
      nil ->
        [
          conversation,
          "Create a summary from the conversation in the <conversation> tags " <>
            "so another coding agent can continue the work.",
          summary_template()
        ]
        |> Enum.join("\n\n")

      prior ->
        [
          conversation,
          "Here is the summary of everything before the <conversation> above:\n\n" <>
            "<prior-summary>\n#{prior}\n</prior-summary>",
          summary_update_instructions(),
          summary_template()
        ]
        |> Enum.join("\n\n")
    end
  end

  # The fixed fill-in structure. Every section is kept even when empty, so
  # the model cannot silently omit a category it did not consider.
  defp summary_template do
    """
    Output exactly the Markdown structure shown inside <template>, keeping \
    the section order unchanged. Do not include the <template> tags or any \
    text outside the structure in your response.

    <template>
    ## Objective
    - [one or two brief sentences: what the user is trying to accomplish]

    ## Important Details
    - [constraints/preferences, decisions and why, facts and assumptions, \
    measurements — counts, exit codes, test results, any number observed — \
    exact context needed to continue, or "(none)"]

    ## Work State
    ### Completed
    - [finished work, verified facts, commands run with their outcome, \
    changes made; otherwise "(none)"]
    ### Active
    - [current work, partial changes, investigation state; otherwise "(none)"]
    ### Blocked
    - [blockers, failing commands and their error messages, unknowns; \
    otherwise "(none)"]

    ## Next Move
    1. [immediate concrete action, or "(none)"]
    2. [next action if known, or "(none)"]

    ## Relevant Files
    - [path: why it matters, or "(none)"]
    </template>

    Rules:
    - Keep every section, even when empty.
    - Use terse bullets, not prose paragraphs.
    - Preserve exact file paths, symbols, commands, error strings, URLs, \
    identifiers and NUMBERS (counts, exit codes, test pass/fail, timings) \
    verbatim — never round or paraphrase a measured value away.
    - Do not mention the summary process or that context was compacted.
    """
    |> String.trim_trailing()
  end

  # The rolling-summary rules (only when a prior summary exists).
  defp summary_update_instructions do
    """
    The <prior-summary> summarizes everything that happened before the \
    <conversation>. Construct a new summary that combines both. The \
    <prior-summary> is discarded after this: anything you do not carry into \
    the new summary is lost.

    When combining:
    - Carry forward objectives, constraints, user directives, decisions and \
    parallel workstreams from the <prior-summary> even when the \
    <conversation> does not mention them. Drop only what is finished and no \
    longer needed.
    - The <conversation> is more recent than the <prior-summary>. Where they \
    conflict, the conversation wins: state the corrected fact and drop the \
    old claim.
    - Add new progress, decisions, constraints and context from the \
    conversation.
    - Move completed work from "Active" to "Completed".
    - If a blocker is resolved, update the summary while keeping details \
    still needed to continue.
    - Update "Objective" and "Next Move" to reflect the current work state.
    """
    |> String.trim_trailing()
  end

  defp render_message(%ReqLLM.Message{role: :assistant} = msg) do
    calls = msg.tool_calls || []
    text = text_of(msg)

    cond do
      calls == [] ->
        "[assistant] #{text}"

      text == "" ->
        "[assistant] → " <> Enum.map_join(calls, "; ", &render_call/1)

      true ->
        "[assistant] #{text}\n→ " <> Enum.map_join(calls, "; ", &render_call/1)
    end
  end

  defp render_message(%ReqLLM.Message{role: :tool} = msg) do
    name = msg.name || "tool"
    "[tool:#{name}] #{truncate(text_of(msg), @render_result_chars)}"
  end

  defp render_message(%ReqLLM.Message{role: role} = msg) do
    "[#{role}] #{text_of(msg)}"
  end

  defp render_message(_), do: ""

  defp render_call(call) do
    {_id, name, args} = ToolCall.normalize(call)

    case args do
      m when map_size(m) == 0 -> name
      m -> "#{name}(#{Jason.encode!(m)})"
    end
  end

  # Concatenated text of a message's content parts/binary, trimmed.
  defp text_of(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp text_of(%ReqLLM.Message{content: c}) when is_binary(c), do: c
  defp text_of(_), do: ""

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    head = String.slice(text, 0, max)

    head <>
      "\n\n[... truncated for the summary: #{byte_size(text)} chars total, showing first #{max} ...]"
  end

  defp bound_input(text) when byte_size(text) <= @max_summary_input_chars, do: text

  defp bound_input(text) do
    # Keep the head (the older, already-summarized context is often
    # repetitive) and the tail (the most recent, most relevant facts)
    # roughly evenly; the marker makes the loss honest.
    half = div(@max_summary_input_chars, 2)
    head = binary_part(text, 0, half)
    tail = binary_part(text, byte_size(text) - half, half)

    head <>
      "\n\n[... summarize input truncated: #{byte_size(text)} chars total; " <>
      "showing first and last #{half} ...]\n\n" <> tail
  end

  @doc """
  Deterministic last-resort trim (ADR 037, the hard-limit fallback):
  drops the oldest complete exchanges — the system message is pinned —
  until the estimated tokens are under `target_tokens`, always keeping
  `min_keep/0` recent messages. Returns `{:ok, context, dropped_count}`
  or `:none` when nothing can be dropped.

  This is lossy by design: it is the alternative to sending a request
  the provider would reject. `render`/`apply` remain the normal path.
  """
  @spec trim(Context.t(), pos_integer()) :: {:ok, Context.t(), non_neg_integer()} | :none
  def trim(%Context{messages: msgs} = ctx, target_tokens) do
    {pinned, convo} = take_pinned(msgs)

    cond do
      convo == [] ->
        :none

      estimated_tokens(pinned ++ convo) <= target_tokens ->
        :none

      true ->
        keep = trim_keep(convo, target_tokens, pinned)
        dropped = length(convo) - length(keep)

        if dropped <= 0 do
          :none
        else
          {:ok, %Context{ctx | messages: pinned ++ keep}, dropped}
        end
    end
  end

  # Drop from the front in whole exchanges; stop when under target or
  # when only min_keep messages would remain.
  defp trim_keep(convo, target_tokens, pinned) do
    if length(convo) <= @min_keep or estimated_tokens(pinned ++ convo) <= target_tokens do
      convo
    else
      # advance past the first complete exchange (user, or assistant+tool
      # results) and recurse
      trimmed = drop_first_exchange(convo)

      if length(trimmed) >= length(convo) do
        convo
      else
        trim_keep(trimmed, target_tokens, pinned)
      end
    end
  end

  # Drop one leading exchange: a :user message, or an :assistant message
  # and the :tool results that answer it.
  defp drop_first_exchange([%ReqLLM.Message{role: :user} | rest]), do: rest

  defp drop_first_exchange([%ReqLLM.Message{role: :assistant} | rest]) do
    drop_leading_tools(rest)
  end

  # a context that does not begin with a user/assistant message: drop the
  # single leading message so the recursion always advances
  defp drop_first_exchange([_ | rest]), do: rest

  defp drop_leading_tools([%ReqLLM.Message{role: :tool} | rest]), do: drop_leading_tools(rest)
  defp drop_leading_tools(rest), do: rest

  @doc "Estimated tokens of a message list (chars/4)."
  @spec estimated_tokens(list()) :: non_neg_integer()
  def estimated_tokens(msgs), do: div(total_chars(msgs), 4)

  @doc "Total chars over all message text parts — the cheap size proxy."
  @spec total_chars(list()) :: non_neg_integer()
  def total_chars(msgs), do: Enum.reduce(msgs, 0, fn m, acc -> acc + message_chars(m) end)

  @doc "Chars over the span that would actually be summarized (excludes system)."
  @spec span_chars(list()) :: non_neg_integer()
  def span_chars(msgs) do
    {system, convo} = take_system(msgs)
    total_chars(system) + total_chars(convo)
  end

  defp message_chars(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.reduce(parts, 0, fn
      %ReqLLM.Message.ContentPart{text: t}, acc when is_binary(t) -> acc + String.length(t)
      _, acc -> acc
    end)
  end

  defp message_chars(%ReqLLM.Message{content: c}) when is_binary(c), do: String.length(c)
  defp message_chars(_), do: 0

  # Chars fallback threshold — ONLY consulted on the first turn (usage
  # unknown). Known-but-below usage never falls back to this: the old
  # 80K-chars trigger fired at ~20K tokens on fat contexts and stalled
  # every turn behind a minutes-long summarize call (found live).
  @chars_fallback 80_000

  defp trigger_chars, do: @chars_fallback

  defp compact_summary_text(summary) do
    """
    [Conversation summary — earlier messages were compacted to save
    context. The recent exchanges below are verbatim.]

    #{summary}
    """
  end

  # The inverse of `compact_summary_text/1` for the rolling-summary path:
  # the prior summary text without our wrapper, so it can be fed back as
  # `<prior-summary>` and combined rather than nested.
  # The inverse of `compact_summary_text/1` for the rolling-summary path:
  # the prior summary text without our wrapper, or `nil` when there is no
  # body (a header-only message — review N21: returning the header itself
  # made `summary_prompt/2` take the roll branch with the summary-as-prior).
  defp strip_summary_prefix(text) do
    case String.split(text, "\n\n", parts: 2) do
      [_header, rest] ->
        case String.trim(rest) do
          "" -> nil
          body -> body
        end

      _ ->
        nil
    end
  end
end
