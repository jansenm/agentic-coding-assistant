defmodule CodingAgent.Core.Tools.TodoWrite do
  @moduledoc """
  The model's todo list (ADR 031).

  A ``todowrite`` call carries the **complete** list and REPLACES the
  stored one; there are no add/remove/update verbs and no per-item ids,
  so there is no merge semantics to get wrong. The session owns the
  state (``Session.State.todos``), injects the current list into every
  request, and the TUI renders it.

  Like ``question``/``task``, the call is intercepted by the session
  before execution: the callback here is a loud safety net, so a call
  that ever reaches ``ToolRunner`` is a visible bug, not a silent no-op.
  """

  alias CodingAgent.Core.Tools

  @tool_name "todowrite"

  @statuses ~w(pending in_progress completed)

  @doc "Whether `name` is the todo-write tool."
  @spec name() :: String.t()
  def name, do: @tool_name

  @doc "The three states a todo may carry."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(_scope) do
    ReqLLM.Tool.new!(
      name: @tool_name,
      description: """
      Maintain a todo list to track multi-step work and show the user
      your plan and progress.

      Send the COMPLETE list on every call — it replaces the previous
      list. An item you leave out is removed, so re-send every item that
      is still relevant.

      Each item has:
      - `content`: the task, in imperative form ("Fix the parser");
      - `status`: one of `pending`, `in_progress`, `completed`.

      Use it when a task spans several steps, after receiving new
      instructions, or before starting a new plan. Keep exactly one item
      `in_progress` at a time. Mark an item `completed` immediately after
      finishing it, not in a batch at the end. Send `[]` to clear the
      list.

      The list is rendered in the sidebar and re-sent to you on every
      turn; it is not something you need to restate.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "todos" => %{
            "type" => "array",
            "description" => "The complete todo list; replaces the previous one",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "content" => %{
                  "type" => "string",
                  "description" => "The task, imperative and concise"
                },
                "status" => %{
                  "type" => "string",
                  "enum" => @statuses,
                  "description" => "The item's state"
                }
              },
              "required" => ["content", "status"]
            }
          }
        },
        "required" => ["todos"]
      },
      callback: fn _args ->
        Tools.error(
          "the todowrite tool is handled by the session, not executed; " <>
            "this call reached execution, which is a bug"
        )
      end
    )
  end

  @doc """
  Parses tool arguments into the canonical todo list, or `{:error,
  reason}` when the shape is wrong. Lenient about string/atom keys (tool
  arguments arrive as maps with string keys). Content is flattened to one
  line (the sidebar renders one row per item) and an unknown status is an
  error rather than a silent default.
  """
  @spec parse(map()) :: {:ok, [map()]} | {:error, String.t()}
  def parse(args) do
    case Map.get(args, "todos") || Map.get(args, :todos) do
      list when is_list(list) -> parse_items(list)
      other -> {:error, "`todos` must be an array, got: #{inspect(other)}"}
    end
  end

  defp parse_items(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case parse_item(item) do
        {:ok, todo} -> {:cont, {:ok, [todo | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, todos} -> {:ok, Enum.reverse(todos)}
      error -> error
    end
  end

  defp parse_item(item) when is_map(item) do
    content = Map.get(item, "content") || Map.get(item, :content)
    status = Map.get(item, "status") || Map.get(item, :status)

    cond do
      not is_binary(content) or String.trim(content) == "" ->
        {:error, "each todo needs a non-empty `content`"}

      status not in @statuses ->
        {:error,
         "todo `status` must be one of #{Enum.join(@statuses, ", ")}, got: #{inspect(status)}"}

      true ->
        {:ok, %{"content" => flatten(content), "status" => status}}
    end
  end

  defp parse_item(other), do: {:error, "each todo must be an object, got: #{inspect(other)}"}

  # One line per item: a newline in model-supplied content would break the
  # sidebar's row math. The text survives; the line break does not.
  defp flatten(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
