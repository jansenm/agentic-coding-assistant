defmodule CodingAgent.Core.Compaction do
  @moduledoc """
  Working-context compaction (slice 4b): the short-term memory tier.

  The message history sent to the LLM grows fast (tool outputs are the
  bulk) and, unchecked, reaches the model's window mid-task. Compaction
  summarizes the *old* part of the conversation and keeps the recent
  tail verbatim — the model keeps working with a compact summary plus
  fresh detail, instead of failing on window overflow.

  Design (docs/source/explanation/memory.rst):

  - **Trigger**: context volume (chars over all messages) crossing a
    threshold, checked before each LLM call — cheap, no tokenizer.
  - **Boundary**: the summary covers everything except the last
    `@keep_recent` messages (never compact the freshest exchanges —
    that is what the model is about to reason over).
  - **The summary is produced by the model itself** via a dedicated
    compaction call on the trimmed history; a summary message replaces
    the compacted span.
  - **Dual view note (v1)**: the CLI transcript is ephemeral, so v1
    compaction rewrites the agent view only. When the dual-view
    transcript lands (phase 5), the display view is the immutable
    record this operation must never touch.

  Compaction is LLM-cost-aware: it runs at most once per turn and
  never runs again until the context grows past the threshold again.
  """

  alias ReqLLM.Context

  @trigger_chars 80_000
  @keep_recent 6

  def trigger_chars, do: @trigger_chars
  def keep_recent, do: @keep_recent

  @doc """
  Returns the compaction plan for a context: `:none` when below the
  threshold, otherwise {:ok, summary_span, keep_span} where the spans
  are lists of messages.
  """
  @spec plan(Context.t()) :: :none | {:ok, summary_span :: list(), keep_span :: list()}
  def plan(%Context{messages: msgs}) do
    total = total_chars(msgs)

    if total < @trigger_chars do
      :none
    else
      {old, keep} = split_at(msgs, @keep_recent)
      {:ok, old, keep}
    end
  end

  @doc """
  Applies a plan: replaces the summarized span with one synthetic user
  message carrying the summary. Returns the new context (or the
  original when there is nothing to compact).
  """
  @spec apply(Context.t(), summary_text :: String.t()) :: Context.t()
  def apply(%Context{messages: msgs} = ctx, summary_text) do
    {old, keep} = split_at(msgs, @keep_recent)

    if old == [] do
      ctx
    else
      summary_msg = %ReqLLM.Message{
        role: :user,
        content: [ReqLLM.Message.ContentPart.text(compact_summary_text(summary_text))]
      }

      %Context{ctx | messages: [summary_msg | keep]}
    end
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

  defp split_at(msgs, keep_recent) when length(msgs) > keep_recent do
    Enum.split(msgs, length(msgs) - keep_recent)
  end

  defp split_at(_, _), do: {[], []}

  defp compact_summary_text(summary) do
    """
    [Conversation summary — earlier messages were compacted to save
    context. The recent exchanges below are verbatim.]

    #{summary}
    """
  end
end
