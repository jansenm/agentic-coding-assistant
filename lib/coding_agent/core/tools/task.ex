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
      Delegate a self-contained task to a subagent and get back its
      summary. Use this when a job is self-contained and would otherwise
      fill your own context: exploring the codebase, hunting down
      references, reading a large area before you decide. The subagent
      runs with its own isolated context and returns only a summary —
      you never see its transcript.

      Usage notes:
      - `prompt` must be a complete, self-contained instruction: the
        subagent does not see this conversation.
      - Give it the goal and the question to answer, not a list of steps.
      - One focused task per call; call it several times (in one round)
        for independent jobs.
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
      [] -> "(none configured — write one in .coding-agent/agents/)"
      names -> Enum.map_join(names, "\n", &"  - #{&1}")
    end
  end
end
