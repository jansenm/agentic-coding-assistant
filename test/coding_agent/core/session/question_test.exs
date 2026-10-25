defmodule CodingAgent.Core.Session.QuestionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Tools.Question

  @tmp_root System.tmp_dir!() |> Path.join("agent-question-#{System.unique_integer()}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    :ok
  end

  defp start(id, opts) do
    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        Keyword.merge(
          [id: id, scope_root: @tmp_root, policy: Permissions.load(nil, nil), test_mode: true],
          opts
        )
      )
  end

  defp question_call do
    %{
      id: "q1",
      name: "question",
      arguments: %{
        "questions" => [
          %{
            "question" => "Which engine?",
            "header" => "Engine",
            "options" => [%{"label" => "fd"}, %{"label" => "pure-Elixir"}]
          }
        ]
      }
    }
  end

  describe "the question tool (ADR 027)" do
    test "is registered and named" do
      assert Question.name() == "question"
      names = CodingAgent.Core.Tools.all(%{root: @tmp_root}) |> Enum.map(& &1.name)
      assert "question" in names
    end

    test "an interactive question call pauses and holds the round" do
      id = "q-pause-#{System.unique_integer()}"
      start(id, interactive: true)

      :ok = Session.debug_gate(id, [question_call()])

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted
      assert [%{"question" => "Which engine?"}] = state.question_pause.questions
      assert length(state.question_pause.calls) == 1
    end

    test "answering runs the round with the formatted result" do
      id = "q-answer-#{System.unique_integer()}"
      start(id, interactive: true)

      :ok = Session.debug_gate(id, [question_call()])
      {:ok, _} = Session.answer_question(id, [["fd"]])

      {:ok, state} = Session.state(id)
      assert state.question_pause == nil

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ ~s("Which engine?"="fd")
      assert text =~ "You can now continue with the user's answers in mind."
    end

    test "an unanswered question renders as Unanswered" do
      id = "q-blank-#{System.unique_integer()}"
      start(id, interactive: true)

      :ok = Session.debug_gate(id, [question_call()])
      {:ok, _} = Session.answer_question(id, [[]])

      {:ok, state} = Session.state(id)

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "Unanswered"
    end

    test "a non-interactive session answers unavailable instead of hanging" do
      id = "q-noninteractive-#{System.unique_integer()}"
      start(id, interactive: false)

      log = capture_log(fn -> :ok = Session.debug_gate(id, [question_call()]) end)

      # a question with no human channel is answered synthetically and LOGGED
      assert log =~ "question asked with no interactive driver"

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      assert state.question_pause == nil

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "not available"
    end

    test "a malformed question does not pause; it returns a fixable error" do
      id = "q-malformed-#{System.unique_integer()}"
      start(id, interactive: true)

      bad = %{id: "b1", name: "question", arguments: %{"questions" => []}}
      :ok = Session.debug_gate(id, [bad])

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      assert state.question_pause == nil

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "non-empty array"
    end

    test "an answer outside a question pause is refused" do
      id = "q-none-#{System.unique_integer()}"
      start(id, interactive: true)
      assert {:error, {:not_at_question, :idle}} = Session.answer_question(id, [["x"]])
    end

    test "a question round with siblings holds all calls until answered" do
      id = "q-sibling-#{System.unique_integer()}"
      start(id, interactive: true)

      write = %{
        id: "w1",
        name: "write_file",
        arguments: %{"path" => "from-question.txt", "content" => "x"}
      }

      :ok = Session.debug_gate(id, [write, question_call()])

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted

      refute File.exists?(Path.join(@tmp_root, "from-question.txt")),
             "the sibling write must wait for the answer"

      {:ok, _} = Session.answer_question(id, [["fd"]])
      assert File.read!(Path.join(@tmp_root, "from-question.txt")) == "x"
    end
  end

  defp message_text(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp message_text(%ReqLLM.Message{content: t}) when is_binary(t), do: t
  defp message_text(_), do: ""
end
