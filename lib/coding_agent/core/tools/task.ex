defmodule CodingAgent.Core.Tools.Task do
  @moduledoc """
  Delegate a self-contained task to a subagent (ADR 017/018).

  This tool does **not execute a callback in the ordinary sense**: a
  `task` call starts a CHILD session with its own isolated context, runs
  it to completion, and returns only the child's summary. That requires
  the parent session's resolved config (model, policy, mounts, depth), so
  the session's gate intercepts the call and runs it
  (`Core.Session.Subagent`); the callback here is a safety net — a `task`
  call that ever reaches execution is a bug, and it says so loudly.

  Depth is 1: a subagent may not start another subagent, so the tool is
  not advertised inside a child session (`Tools.delegation/1` returns
  nothing when the scope carries `depth > 0`).
  """

  alias CodingAgent.Core.Tools

  @tool_name "task"

  @doc "Whether `name` is the task tool."
  @spec name() :: String.t()
  def name, do: @tool_name

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: @tool_name,
      description: """
      Delegate a self-contained, read-heavy job to a subagent and get back
      its summary. The subagent runs with its own isolated context — a
      scratchpad you can throw away — and returns only a final summary;
      you never see its transcript, its reasoning or its tool calls.

      Delegate when the *search* is much larger than the *answer*: hunting
      down where something is defined or used, reading a large area before
      you decide, gathering facts from many files to act on a few. That is
      work whose intermediate noise you do not want filling your context.

      Do NOT delegate when:
      - you need the raw facts, only a summary comes back;
      - the job depends on THIS conversation — the subagent cannot see it;
      - it is one or two tool calls — just make them;
      - you must own the result (edits, writes) — you cannot review a diff
        you never saw, and subagents report in prose.

      Usage notes:
      - `prompt` is the whole context: a complete, self-contained
        instruction naming the goal and the question, not a list of steps.
      - One focused task per call; call it several times (in one round) for
        independent jobs — those run in parallel.
      - A subagent may not start further subagents.

      Available subagents:
      #{subagent_list(scope)}
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "description" => %{
            "type" => "string",
            "description" => "A short (3-5 word) description of the task"
          },
          "prompt" => %{
            "type" => "string",
            "description" => "The task for the subagent; it does not see this conversation"
          },
          "subagent_type" => %{
            "type" => "string",
            "description" => "The subagent to use, by name"
          }
        },
        "required" => ["description", "prompt", "subagent_type"]
      },
      callback: fn _args ->
        Tools.error(
          "the task tool is handled by the session, not executed; " <>
            "this call reached execution, which is a bug"
        )
      end
    )
  end

  defp subagent_list(scope) do
    case Map.get(scope, :subagents, []) do
      [] ->
        "(none configured — add a `mode: subagent` definition under " <>
          ".coding-agent/agents/)"

      subs ->
        Enum.map_join(subs, "\n", fn
          %{name: name, description: desc} when is_binary(desc) and desc != "" ->
            "  - #{name} — #{desc}"

          %{name: name} ->
            "  - #{name}"

          name when is_binary(name) ->
            "  - #{name}"
        end)
    end
  end
end
