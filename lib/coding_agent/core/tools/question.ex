defmodule CodingAgent.Core.Tools.Question do
  @moduledoc """
  Ask the human a structured question mid-turn (ADR 027).

  This tool does **not execute a callback in the ordinary sense**: a
  question cannot block inside `ToolRunner`, so the session's gate
  intercepts a `question` call, parks the turn, and answers it when the
  human replies (`Session.answer_question/2`). The callback here is a
  safety net — a question call that ever reaches execution is a bug, and
  it says so loudly instead of deadlocking.

  The schema follows opencode's (`tool/question.ts`): each question has a
  `question` text, an optional `header`, a list of `options`
  (`label`/`description`), and a `multiple` flag.
  """

  alias CodingAgent.Core.Tools

  @tool_name "question"

  @doc "Whether `name` is the question tool."
  @spec name() :: String.t()
  def name, do: @tool_name

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(_scope) do
    ReqLLM.Tool.new!(
      name: @tool_name,
      description: """
      Use this tool when you need to ask the human a question during
      execution. Use it to:

      1. Gather a preference or a requirement you cannot infer;
      2. Clarify an ambiguous instruction;
      3. Get a decision on an implementation choice — especially before
         widening the scope of the task;
      4. Offer choices about which direction to take.

      Usage notes:
      - A "type your own answer" option is always offered, so do NOT add
        an "Other" or catch-all option yourself.
      - To allow more than one choice per question, set `multiple: true`.
      - If you recommend an option, put it FIRST and end its label with
         " (Recommended)".
      - Prefer a question over guessing. Keep the options short.

      Rendering:
      - The question text is rendered as MARKDOWN: paragraphs, line
        breaks, bold and inline code all work, so format code as
        `inline code`.
      - `header`, option `label` and `description` are flattened to a
        single line before display — do NOT put newlines or multi-line
        blocks there.
      - Fenced code blocks (```) are NOT highlighted; their markers show
        literally. Prefer inline code for short snippets and keep any
        code short.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "questions" => %{
            "type" => "array",
            "description" => "The questions to ask, in order",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "question" => %{
                  "type" => "string",
                  "description" => "The complete question to ask the human"
                },
                "header" => %{
                  "type" => "string",
                  "description" => "A very short label (max ~30 chars)"
                },
                "options" => %{
                  "type" => "array",
                  "description" => "The choices; each is a label plus optional description",
                  "items" => %{
                    "type" => "object",
                    "properties" => %{
                      "label" => %{"type" => "string"},
                      "description" => %{"type" => "string"}
                    },
                    "required" => ["label"]
                  }
                },
                "multiple" => %{
                  "type" => "boolean",
                  "description" => "Allow selecting more than one option (default false)"
                }
              },
              "required" => ["question", "options"]
            }
          }
        },
        "required" => ["questions"]
      },
      callback: fn _args ->
        Tools.error(
          "the question tool is answered by the session, not executed; " <>
            "this call reached execution, which is a bug"
        )
      end
    )
  end
end
