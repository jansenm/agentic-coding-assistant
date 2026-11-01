defmodule CodingAgent.UI.DialogsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Dialogs
  alias ExRatatui.Layout.Rect

  # The dialogs are painters: which surface is up is the TUI's decision,
  # what each one says is `Dialogs`'s. Both halves are assertable here —
  # no terminal, no session.

  @area %Rect{x: 0, y: 0, width: 100, height: 30}
  @input_h 5

  defp widgets(opts), do: Dialogs.widgets(Dialogs.new(opts), @area, @input_h)

  test "no prompt paints nothing, so the renderer appends unconditionally" do
    assert widgets([]) == []
  end

  test "the approval gate names the call and the keys, and hides while deciding" do
    call = %{id: "c1", name: "shell", arguments: %{"command" => "ls"}}

    [{%ExRatatui.Widgets.Clear{}, _}, {widget, _rect}] = widgets(pending: [call])
    assert widget.block.title == " APPROVAL 1/1 "
    assert widget.text =~ "shell(command: ls)"
    assert widget.text =~ "y = approve"

    assert widgets(pending: [call], deciding?: true) == []
  end

  test "an escalation's reason is shown as why:, and not repeated in the args" do
    call = %{
      id: "c1",
      name: "shell",
      arguments: %{"command" => "git push", "reason" => "the user asked", "network" => true}
    }

    [_, {widget, _}] = widgets(pending: [call])

    assert widget.text =~ "why: the user asked"
    # the raw argument list must not say it twice
    assert length(String.split(widget.text, "the user asked")) == 2
    assert widget.text =~ "network: true"
  end

  test "the budget and doom prompts name the numbers the human is deciding about" do
    [_, {budget, _}] = widgets(budget: 25)
    assert budget.block.title == " TOOL BUDGET "
    assert budget.text =~ "25-round tool budget"

    [_, {doom, _}] = widgets(doom: "read_file")
    assert doom.block.title == " DOOM LOOP "
    assert doom.text =~ "read_file was called 3 times"
  end

  # The wizard body is Markdown, so model-supplied text must not be able to
  # open a block of its own: a newline in a label would leave the bold term
  # unclosed, and a blank line in a description escapes the def-list.
  test "model text is flattened to one line in every option row" do
    options = [
      %{"label" => "evil\n>\n\n## heading", "description" => "a\nb"},
      %{"label" => "plain"}
    ]

    body = Dialogs.options_deflist(options, [0])

    # the newlines are gone: the label is inline in the bold term, and the
    # description is a single ": " line under it
    assert body =~ "▸ **1) evil > ## heading**"
    assert String.split(body, "\n") |> Enum.member?(": a b")

    # nothing the model wrote opens a block of its own
    refute Enum.any?(String.split(body, "\n"), &String.starts_with?(&1, "#"))
  end

  test "the wizard separates option blocks with a blockquote (a blank line paints none)" do
    body = Dialogs.options_deflist([%{"label" => "a"}, %{"label" => "b"}], [])
    assert body =~ "\n\n>\n\n"
  end

  test "the wizard body carries the question, the controls and the free-text row" do
    question = %{"question" => "Which?", "options" => [%{"label" => "fd"}]}
    qp = %{questions: [question], index: 0, selected: [0], answers: [], custom: nil}

    body = Dialogs.question_markdown(question, qp, question["options"])

    assert body =~ "Which?"
    assert body =~ "enter = confirm   esc = skip"
    assert body =~ "0) type your own answer…"
    # one question: no progress suffix
    refute body =~ "question 1/"
  end

  test "a multi-select question says so and a multi-question wizard counts" do
    q = %{"question" => "Pick", "multiple" => true, "options" => [%{"label" => "a"}]}
    qp = %{questions: [q, q], index: 1, selected: [], answers: [["a"]], custom: nil}

    body = Dialogs.question_markdown(q, qp, q["options"])
    assert body =~ "(select one or more)"
    assert body =~ "question 2/2"
  end

  test "long argument values are capped and multiline ones are inspected" do
    args = %{"path" => String.duplicate("x", 300), "content" => "a\nb"}

    lines = args |> Dialogs.pretty_args() |> String.split("\n")

    # one line per argument, whatever the map's iteration order is
    assert length(lines) == 2
    path_line = Enum.find(lines, &String.starts_with?(&1, "path: "))
    assert String.length(path_line) == String.length("path: ") + 160
    assert Enum.any?(lines, &(&1 =~ ~s(content: "a\\nb")))
  end
end
