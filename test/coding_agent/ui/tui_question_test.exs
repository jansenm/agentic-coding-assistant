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

  test "the wizard paints long question text wrapped, not clipped" do
    root = Path.join(System.tmp_dir!(), "tui-q3-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q3-#{System.unique_integer()}"

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

    long =
      "Should the transcript measurement stay lazy when the window is very tall and the session holds thousands of entries?"

    :ok =
      CodingAgent.Core.Session.debug_gate(sid, [
        %{
          id: "q2",
          name: "question",
          arguments: %{
            "questions" => [
              %{
                "question" => long,
                "header" => "Long",
                "options" => [
                  %{
                    "label" => "keep lazy",
                    "description" =>
                      "Measure only what the viewport needs, exactly as ADR 028 decided"
                  },
                  %{
                    "label" => "pre-warm the rest",
                    "description" => "Trade idle CPU for scroll latency"
                  }
                ]
              }
            ]
          }
        }
      ])

    wait_until(fn -> sync(pid).question_prompt != nil end)

    buf = buffer(pid) |> Enum.join("\n")

    # the question text is present in full: both a wrapped first line and
    # its continuation exist (a clipped paragraph would drop the tail)
    assert buf =~ "Should the transcript"
    assert buf =~ "thousands of entries"

    # the definition-list form: the term row and its description line,
    # with a blank row between the answer blocks (the blockquote-gap
    # trick in options_deflist). The CONTROLS row is not asserted here:
    # the gaps make the dialog two rows taller, and on the 24-row test
    # window the room clamp drops the bottom rows — measured (the
    # composer + band own the rest).
    assert buf =~ "1) keep lazy"
    assert buf =~ ": Measure only what the viewport"
    assert buf =~ "0) type your own answer…"
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
