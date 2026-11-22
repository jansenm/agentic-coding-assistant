# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.Compact do
  @moduledoc """
  The model's own compaction lever (ADR 040 open question 1, answered
  2026-09-30).

  Until now the agent could SEE its context budget (ADR 040's injected
  block) but had no lever beyond ending its turn: compaction was
  runtime-driven only. In a long, search-heavy turn — the exact shape the
  budget block was built for — the model would notice it was running out
  of room and could do nothing about it; the hard pass would summarize
  the older span *between tool rounds*, losing detail the model was mid-
  way through using.

  This tool gives it the same verb the human has (`/compact`, ctrl-x c):
  summarize the older span NOW, keeping the recent exchanges verbatim.
  Like `/compact` it ignores the soft/hard thresholds — "is it over a
  line?" is the wrong question when the model has decided it wants
  headroom.

  Like ``question``/``task``/``todowrite``, the call is intercepted by
  the session before execution (the summary is a provider call the
  session must run with the right model/provider), so the callback here
  is a loud safety net: a call that reaches ``ToolRunner`` is a visible
  bug, not a silent no-op.
  """

  alias CodingAgent.Core.Tools

  @tool_name "compact"

  @doc "Whether `name` is the compact tool."
  @spec name() :: String.t()
  def name, do: @tool_name

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(_scope) do
    ReqLLM.Tool.new!(
      name: @tool_name,
      description: """
      Summarize older messages to free context, keeping the MOST RECENT
      exchanges verbatim. Use this when you are running low on context
      (see the "Context budget" line) but still have work to do: it
      compacts NOW instead of waiting for your turn to end. The older
      noise is folded into a summary; anything OLDER than the last few
      exchanges is no longer available verbatim.

      When NOT to use it:
      - Early in a task, or when you have plenty of context left — there
        is nothing useful to summarize yet ("nothing to compact").
      - Right before you need exact older detail you have not written
        down: the old span is replaced by its summary. Put anything
        durable in a todo's `notes` first — those survive compaction.

      The tool takes no arguments and returns a one-line result saying
      whether a summary was applied and roughly how much was reclaimed.
      """,
      parameter_schema: %{type: "object", properties: %{}, required: []},
      callback: fn _args ->
        Tools.error(
          "the compact tool is handled by the session, not executed; " <>
            "this call reached execution, which is a bug"
        )
      end
    )
  end
end
