# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

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

  # Bounds (review: todowrite was the only tool with no ceiling, yet its
  # block rides EVERY request and is persisted). A plan is a handful of
  # steps; these caps keep a runaway list from bloating the system prompt.
  @max_items 64
  @max_content_chars 500

  # `notes` is the agent-private half of an item: not rendered in the
  # sidebar, only read back in the injected block. It is where durable
  # facts live that compaction must not lose (paths, numbers, decisions).
  # Per-item AND total caps, because notes ride every request too and a
  # max-length note on each of 64 items would bloat the prompt.
  #
  # The per-item cap is generous (review: a legitimate note was bounced at
  # 589 chars, and the lossy re-write cost more context than the note). A
  # fact worth keeping is prose with hashes in it, not a haiku. 1000 still
  # bounds the block: at the 64-item ceiling the worst case is the total
  # cap, not 64 x 1000. The total keeps the old ratio — 8 max-length notes.
  @max_notes_chars 1_000
  @max_notes_total_chars 8_000

  @doc "Whether `name` is the todo-write tool."
  @spec name() :: String.t()
  def name, do: @tool_name

  @doc """
  The call arguments that name filesystem paths, for the permission gate.
  """
  @spec path_arguments() :: [Tools.path_argument()]
  def path_arguments, do: []

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
      - `status`: one of `pending`, `in_progress`, `completed`;
      - `notes` (optional): private working memory you keep for yourself.
        It is NOT shown in the user's panel; it is read back to you in
        this block on every request. Use it to hold facts you must not
        lose when the conversation is summarized — exact paths, test
        counts, decisions and why, measured numbers. A note may run to
        #{@max_notes_chars} characters (and #{@max_notes_total_chars} across the
        whole list), so write the fact out rather than abbreviating it
        into something you will have to re-derive later.

      Use it when a task spans several steps, after receiving new
      instructions, or before starting a new plan. Keep exactly one item
      `in_progress` at a time. Mark an item `completed` immediately after
      finishing it, not in a batch at the end. Send `[]` to clear the
      list.

      The list is rendered in the sidebar and re-sent to you on every
      turn; it is not something you need to restate. Keep it to at most
      #{@max_items} items with a short imperative line each.
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
                },
                "notes" => %{
                  "type" => "string",
                  "description" =>
                    "Optional private memory for this item (not shown in the " <>
                      "panel; read back to you each request). Hold facts that " <>
                      "must survive summarization: paths, numbers, decisions. " <>
                      "Up to #{@max_notes_chars} characters."
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
      list when is_list(list) ->
        cond do
          length(list) > @max_items ->
            {:error, "too many todos (#{length(list)}); the limit is #{@max_items}"}

          notes_total(list) > @max_notes_total_chars ->
            {:error,
             "todo `notes` are too long in total (limit #{@max_notes_total_chars} chars, " <>
               "you wrote #{notes_total(list)}); keep each item's notes to the facts " <>
               "compaction must not lose"}

          true ->
            parse_items(list)
        end

      other ->
        {:error, "`todos` must be an array, got: #{inspect(other)}"}
    end
  end

  defp notes_total(list) do
    Enum.reduce(list, 0, fn item, acc ->
      case Map.get(item, "notes") || Map.get(item, :notes) do
        n when is_binary(n) -> acc + String.length(n)
        _ -> acc
      end
    end)
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
    notes = Map.get(item, "notes") || Map.get(item, :notes)

    cond do
      not is_binary(content) or String.trim(content) == "" ->
        {:error, "each todo needs a non-empty `content`"}

      String.length(content) > @max_content_chars ->
        {:error,
         "a todo `content` is too long (limit #{@max_content_chars} chars, " <>
           "you wrote #{String.length(content)})"}

      status not in @statuses ->
        {:error,
         "todo `status` must be one of #{Enum.join(@statuses, ", ")}, got: #{inspect(status)}"}

      notes != nil and not is_binary(notes) ->
        {:error, "todo `notes` must be a string, got: #{inspect(notes)}"}

      is_binary(notes) and String.length(notes) > @max_notes_chars ->
        {:error,
         "a todo `notes` is too long (limit #{@max_notes_chars} chars, " <>
           "you wrote #{String.length(notes)})"}

      true ->
        {:ok, put_notes(%{"content" => flatten(content), "status" => status}, notes)}
    end
  end

  defp parse_item(other), do: {:error, "each todo must be an object, got: #{inspect(other)}"}

  # `notes` is kept as-is (not flattened to one line): it never reaches the
  # sidebar, only the model, so line breaks are useful structure. A blank
  # note is dropped, so the item shape stays minimal.
  defp put_notes(todo, notes) when is_binary(notes) do
    case String.trim(notes) do
      "" -> todo
      trimmed -> Map.put(todo, "notes", trimmed)
    end
  end

  defp put_notes(todo, _), do: todo

  # One line per item: a newline in model-supplied content would break the
  # sidebar's row math. The text survives; the line break does not.
  defp flatten(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
