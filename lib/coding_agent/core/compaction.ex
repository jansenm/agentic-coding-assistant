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

  - **Trigger**: the provider's own last-turn input_tokens (ground
    truth — chars estimates drift) crossing an ABSOLUTE token
    threshold; chars are only the first-turn fallback when no usage
    data exists. The trigger decision itself is the Compactor's.
  - **Boundary**: the summary covers everything except the last
    `@keep_recent` messages (never compact the freshest exchanges —
    that is what the model is about to reason over).
  - **The summary is produced by the model itself** via a dedicated
    compaction call on the rendered old span; a summary message
    replaces the compacted span.
  - **Dual view note (v1)**: the CLI transcript is ephemeral, so v1
    compaction rewrites the agent view only. When the dual-view
    transcript lands (phase 5), the display view is the immutable
    record this operation must never touch.
  """

  alias ReqLLM.Context

  @keep_recent 6

  @default_trigger_tokens 180_000

  def keep_recent, do: @keep_recent
  def default_trigger_tokens, do: @default_trigger_tokens

  @doc """
  First-turn fallback plan (no usage data yet): chars-based, `:none`
  when below `trigger_chars`, otherwise `{:ok, summary_span,
  keep_span}`. The session-level decision (`Session.Compactor.decide/2`)
  only reaches this when usage is genuinely unknown.
  """
  @spec plan(Context.t()) :: :none | {:ok, summary_span :: list(), keep_span :: list()}
  def plan(%Context{messages: msgs}) do
    if total_chars(msgs) < trigger_chars() do
      :none
    else
      split(msgs)
    end
  end

  @doc """
  Token-based trigger: compact when the last observed input_tokens
  cross the absolute threshold (`trigger_tokens`). `last_input_tokens:
  0` (no usage data yet) never triggers — the caller falls back to
  the chars-based plan.
  """
  @spec plan_tokens(Context.t(), non_neg_integer(), pos_integer()) ::
          :none | {:ok, summary_span :: list(), keep_span :: list()}
  def plan_tokens(
        %Context{messages: msgs},
        last_input_tokens,
        trigger_tokens \\ @default_trigger_tokens
      ) do
    if last_input_tokens >= trigger_tokens do
      split(msgs)
    else
      :none
    end
  end

  # The boundary: everything except the last @keep_recent messages.
  defp split(msgs) do
    case msgs do
      msgs when length(msgs) > @keep_recent ->
        {old, keep} = Enum.split(msgs, length(msgs) - @keep_recent)
        {:ok, old, keep}

      # too small to compact anything (old span would be empty)
      _ ->
        :none
    end
  end

  @doc """
  Applies a summary: replaces the summarized span with one synthetic
  user message carrying the summary. Returns the new context (or the
  original when there is nothing to compact).
  """
  @spec apply(Context.t(), summary_text :: String.t()) :: Context.t()
  def apply(%Context{messages: msgs} = ctx, summary_text) do
    case split(msgs) do
      {:ok, _old, keep} ->
        summary_msg = %ReqLLM.Message{
          role: :user,
          content: [ReqLLM.Message.ContentPart.text(compact_summary_text(summary_text))]
        }

        %Context{ctx | messages: [summary_msg | keep]}

      :none ->
        ctx
    end
  end

  @doc """
  Renders the summary span as one text block for the summarizer model —
  the only place message text is flattened for an LLM call. (The UI
  renders its own transcript; that view is display-only and never
  touches compaction.)
  """
  @spec render(list()) :: String.t()
  def render(msgs) do
    Enum.map_join(msgs, "\n\n", fn
      %ReqLLM.Message{role: role, content: parts} when is_list(parts) ->
        text =
          Enum.map_join(parts, "", fn
            %ReqLLM.Message.ContentPart{text: t} when is_binary(t) -> t
            _ -> ""
          end)

        "[#{role}] #{text}"

      %ReqLLM.Message{role: role, content: c} when is_binary(c) ->
        "[#{role}] #{c}"

      _ ->
        ""
    end)
  end

  @doc "Total chars over all message text parts — the cheap size proxy."
  @spec total_chars(list()) :: non_neg_integer()
  def total_chars(msgs) do
    Enum.reduce(msgs, 0, fn msg, acc ->
      acc + message_chars(msg)
    end)
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
end
