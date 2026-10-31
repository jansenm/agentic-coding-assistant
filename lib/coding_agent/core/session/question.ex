defmodule CodingAgent.Core.Session.Question do
  @moduledoc """
  The `question` tool's session side (ADR 027), extracted from `Session`.

  A question is the one tool call the session does not execute: it parks
  the whole round and answers it when the human replies. Both halves of
  that exchange are pure — finding the calls in a round, parsing what the
  model asked, and composing the result text it reads back — so they live
  here instead of inside the GenServer that owns the pause.

  Three consumers share the shape defined here, which is why it is one
  module and not three literals:

    * the pause (`Session.run_round/2` asks whether the round holds a
      question),
    * the answer (`Session.answer_question/2` formats the reply), and
    * the non-interactive fallback (no driver to ask, so the answer is
      synthetic and the turn never hangs — the ADR 025/026 rule).

  The **normalized question map** (`parse/1`) is also what `UI.Tui`'s
  wizard reads (`"question"`, `"header"`, `"multiple"`, `"options"`), so
  the parse and the rendering cannot disagree about a field name.
  """

  alias CodingAgent.Core.ToolCall
  alias CodingAgent.Core.Tools.Question, as: Tool

  @typedoc """
  One parsed question: its text, an optional short header, whether more
  than one option may be picked, and the options (`label` plus optional
  `description`).
  """
  @type question :: %{
          String.t() => String.t() | boolean() | [map()] | nil
        }

  @doc "The tool name (`Tools.Question.name/0` is the definition's)."
  @spec name() :: String.t()
  def name, do: Tool.name()

  @doc """
  The question calls in a round — usually zero or one. Keeping this
  separate lets `Session.execute_round/3` stay free of the branch.
  """
  @spec calls([term()]) :: [term()]
  def calls(calls) do
    Enum.filter(calls, fn call ->
      {_id, name, _args} = ToolCall.normalize(call)
      name == Tool.name()
    end)
  end

  @doc """
  Parses the tool arguments into a normalized question list, or
  `{:error, reason}` when the shape is wrong (the model can fix that in
  the next round). Lenient about string/atom keys: tool arguments arrive
  as maps with string keys, but a decoded test or a resumed call may not.
  """
  @spec parse(map()) :: {:ok, [question()]} | {:error, String.t()}
  def parse(args) do
    raw = Map.get(args, "questions") || Map.get(args, :questions)

    if is_list(raw) and raw != [] do
      {:ok, Enum.map(raw, &parse_question/1)}
    else
      {:error, "`questions` must be a non-empty array"}
    end
  end

  defp parse_question(q) do
    %{
      "question" => q["question"] || q[:question] || "",
      "header" => q["header"] || q[:header],
      "multiple" => q["multiple"] || q[:multiple] || false,
      "options" => normalize_options(q["options"] || q[:options] || [])
    }
  end

  defp normalize_options(options) do
    Enum.map(options, fn o ->
      %{
        "label" => o["label"] || o[:label] || "",
        "description" => o["description"] || o[:description]
      }
    end)
  end

  @doc """
  One tool result per question call, each carrying the formatted answers
  (opencode's shape): `User has answered your questions: "q"="a, b". You
  can now continue…`.

  `answers` is one list of selected labels per question, in order; an
  empty list means the question was left unanswered, which renders as
  `Unanswered` so the model knows the human declined rather than chose
  nothing.
  """
  @spec results([term()], [question()], [[String.t()]]) :: [map()]
  def results(calls, questions, answers) do
    formatted =
      questions
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {q, i} ->
        selected = Enum.at(answers, i) || []

        value =
          case selected do
            [] -> "Unanswered"
            list -> Enum.join(list, ", ")
          end

        ~s("#{q["question"]}"="#{value}")
      end)

    content =
      "User has answered your questions: #{formatted}. " <>
        "You can now continue with the user's answers in mind."

    Enum.map(calls, &result(&1, content))
  end

  @doc """
  The synthetic answer when no interactive driver can be asked. The turn
  proceeds instead of hanging, and the text tells the model what to do
  with that: decide itself, or say the question plainly in its answer.
  """
  @spec unavailable([term()]) :: [map()]
  def unavailable(calls) do
    content =
      "error: the human is not available to answer questions right now. " <>
        "Proceed with your best judgment, or stop and state the question plainly in your answer."

    Enum.map(calls, &result(&1, content))
  end

  defp result(call, content) do
    {id, name, _args} = ToolCall.normalize(call)
    %{id: id, name: name, content: content}
  end
end
