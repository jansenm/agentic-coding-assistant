defmodule CodingAgent.UI.TuiQuestionTest do
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.Tui

  # The question wizard (ADR 027): the agent asks, the TUI shows a dialog,
  # the answer reaches the session as the tool result.

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

  test "the question reaches the TUI; picking an option answers the session" do
    root = Path.join(System.tmp_dir!(), "tui-q-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: sid,
        scope_root: root,
        policy: CodingAgent.Core.Permissions.load(nil, nil),
        test_mode: true,
        interactive: true
      )

    pid =
      start_supervised!(
        {Tui, [name: nil, test_mode: {80, 24}, session_id: sid, scope_root: root]}
      )

    assert sync(pid).question_prompt == nil

    :ok = CodingAgent.Core.Session.debug_gate(sid, [question_call()])

    wait_until(fn -> sync(pid).question_prompt != nil end)
    assert [%{"question" => "Which engine?"}] = sync(pid).question_prompt.questions
    assert sync(pid).status == :interrupted

    # pick option 1 (fd), confirm
    key(pid, "1")
    key(pid, "enter")

    wait_until(fn -> sync(pid).question_prompt == nil end)
  end

  test "esc skips the question and the session proceeds" do
    root = Path.join(System.tmp_dir!(), "tui-q2-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q2-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: sid,
        scope_root: root,
        policy: CodingAgent.Core.Permissions.load(nil, nil),
        test_mode: true,
        interactive: true
      )

    pid =
      start_supervised!(
        {Tui, [name: nil, test_mode: {80, 24}, session_id: sid, scope_root: root]}
      )

    :ok = CodingAgent.Core.Session.debug_gate(sid, [question_call()])
    wait_until(fn -> sync(pid).question_prompt != nil end)

    key(pid, "esc")
    wait_until(fn -> sync(pid).question_prompt == nil end)
  end
end
