defmodule CodingAgent.UI.TuiQuestionTest do
  use CodingAgent.TuiCase, async: true

  import ExUnit.CaptureLog

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

  # Regression (found live 2026-10-31): the dialog advertises
  # "enter = confirm" in its own footer, so a human who wants the model's
  # default presses Enter on the untouched screen. Nothing was selected,
  # `question_confirm/1` collected `[]`, and the model was told
  # `"Which engine?"="Unanswered"` — twice, for two questions, while the
  # human believed both were answered. The first row is the model's
  # default by ADR 027's own ordering rule (recommended option FIRST), so
  # the wizard now opens on it.
  test "enter on an untouched question answers with the model's default" do
    root = Path.join(System.tmp_dir!(), "tui-q-default-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q-default-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]}
      )

    :ok = CodingAgent.Core.Session.debug_gate(sid, [question_call()])
    wait_until(fn -> sync(pid).question_prompt != nil end)

    # the wizard opens ON the first option, and the frame says so
    assert sync(pid).question_prompt.selected == [0]
    assert Enum.join(buffer(pid), "\n") =~ "▸ 1) fd"

    key(pid, "enter")
    wait_until(fn -> sync(pid).question_prompt == nil end)

    {:ok, state} = CodingAgent.Core.Session.state(sid)
    text = context_text(state)

    assert text =~ ~s("Which engine?"="fd")
    refute text =~ "Unanswered"
  end

  # The one case where an untouched question really is unanswered: a
  # MULTI-select question has no single default, and a preselected row
  # would read as "these are the picks". Enter there means "nothing".
  test "a multi-select question starts empty and Enter sends Unanswered" do
    root = Path.join(System.tmp_dir!(), "tui-q-multi-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q-multi-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]}
      )

    :ok =
      CodingAgent.Core.Session.debug_gate(sid, [
        %{
          id: "qm",
          name: "question",
          arguments: %{
            "questions" => [
              %{
                "question" => "Which engines?",
                "multiple" => true,
                "options" => [%{"label" => "fd"}, %{"label" => "pure-Elixir"}]
              }
            ]
          }
        }
      ])

    wait_until(fn -> sync(pid).question_prompt != nil end)
    assert sync(pid).question_prompt.selected == []

    key(pid, "enter")
    wait_until(fn -> sync(pid).question_prompt == nil end)

    {:ok, state} = CodingAgent.Core.Session.state(sid)
    assert context_text(state) =~ ~s("Which engines?"="Unanswered")
  end

  # A preselection must not survive into the NEXT question of a wizard
  # run: question 2 opens on ITS default, not on whatever was picked for
  # question 1.
  test "each question of a multi-question wizard opens on its own default" do
    root = Path.join(System.tmp_dir!(), "tui-q-two-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q-two-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]}
      )

    :ok =
      CodingAgent.Core.Session.debug_gate(sid, [
        %{
          id: "q2",
          name: "question",
          arguments: %{
            "questions" => [
              %{"question" => "One?", "options" => [%{"label" => "a"}, %{"label" => "b"}]},
              %{"question" => "Two?", "options" => [%{"label" => "c"}, %{"label" => "d"}]}
            ]
          }
        }
      ])

    wait_until(fn -> sync(pid).question_prompt != nil end)
    assert sync(pid).question_prompt.index == 0
    assert sync(pid).question_prompt.selected == [0]

    key(pid, "enter")

    qp = sync(pid).question_prompt
    assert qp.index == 1
    assert qp.selected == [0]
    assert qp.answers == [["a"]]

    key(pid, "enter")
    wait_until(fn -> sync(pid).question_prompt == nil end)

    {:ok, state} = CodingAgent.Core.Session.state(sid)
    text = context_text(state)
    assert text =~ ~s("One?"="a")
    assert text =~ ~s("Two?"="c")
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

  test "selecting \"type your own\" clears the option (they are exclusive)" do
    # Regression (found in review): `0` set the custom buffer but left the
    # selected option marked, so BOTH rows painted their ▸ and confirming
    # without typing submitted the option, not the empty custom answer.
    root = Path.join(System.tmp_dir!(), "tui-q4-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q4-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]}
      )

    :ok = CodingAgent.Core.Session.debug_gate(sid, [question_call()])

    wait_until(fn -> sync(pid).question_prompt != nil end)

    key(pid, "1")
    assert sync(pid).question_prompt.selected == [0]

    key(pid, "0")
    qp = sync(pid).question_prompt
    assert qp.custom == ""
    assert qp.selected == []

    # and the option marker is gone from the frame: only the custom row
    # carries ▸ (both marked at once was the visible bug)
    rows = buffer(pid) |> Enum.join("\n")
    refute rows =~ "▸ 1) fd"
    assert rows =~ "▸ 0)"
  end

  test "digits inside a custom answer are text, not option toggles" do
    # Regression (found in review): every digit was routed to
    # question_toggle/2, so typing "42" selected option 4 and wiped the
    # buffer — a numeric answer was impossible.
    root = Path.join(System.tmp_dir!(), "tui-q5-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q5-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]}
      )

    :ok = CodingAgent.Core.Session.debug_gate(sid, [question_call()])

    wait_until(fn -> sync(pid).question_prompt != nil end)

    key(pid, "0")
    key(pid, "4")
    key(pid, "2")

    qp = sync(pid).question_prompt
    assert qp.custom == "42"
    assert qp.selected == []
  end

  test "a multiline label is flattened to one line (no markdown structure escapes)" do
    # Regression (found in review): the label was embedded in the
    # def-list verbatim, so "evil\n>\n\n## heading" closed the bold term
    # and opened a heading/blockquote — model-supplied text could break
    # the option rows out of their structure. One line is the contract.
    root = Path.join(System.tmp_dir!(), "tui-q6-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q6-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]}
      )

    :ok =
      CodingAgent.Core.Session.debug_gate(sid, [
        %{
          id: "q6",
          name: "question",
          arguments: %{
            "questions" => [
              %{
                "question" => "Q?",
                "header" => "H",
                "options" => [
                  %{"label" => "evil\n>\n\n## heading injection", "description" => "d\n\n> q"}
                ]
              }
            ]
          }
        }
      ])

    wait_until(fn -> sync(pid).question_prompt != nil end)

    rows = buffer(pid) |> Enum.join("\n")

    # the text survives, on ONE row, inside the option's own paragraph:
    # the "##" stays literal mid-line (a heading block would paint it at
    # the start of its own row) and no emphasis marker leaks
    assert rows =~ "1) evil > ## heading injection"
    refute Enum.any?(buffer(pid), &Regex.match?(~r/^\s*[│║]?## heading/, &1))
    refute rows =~ "**1)"
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

  test "a late answer reply cannot close the NEXT question's dialog" do
    # Regression (found live): answering Q1, the session immediately asks
    # Q2 (its :question_asked broadcast opens the wizard); only THEN does
    # the answer worker finish. The late {:__question_answered__, {:ok,
    # :interrupted}} reply used to clear the fresh Q2 dialog
    # unconditionally — "the dialog disappears, the band says approval
    # needed". Deterministic here: the broadcasts and the late reply are
    # delivered in exactly that order, no provider needed.
    root = Path.join(System.tmp_dir!(), "tui-q-race-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q-race-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]}
      )

    # Q1 opens
    agent(pid, {:status_changed, :question_asked, %{questions: [%{"question" => "Q1?"}]}})
    assert sync(pid).question_prompt != nil

    # the answer is sent: the optimistic path clears the prompt and runs
    agent(pid, {:status_changed, :running})
    assert sync(pid).question_prompt == nil

    # the worker asks Q2 before the answer reply arrives
    agent(pid, {:status_changed, :question_asked, %{questions: [%{"question" => "Q2?"}]}})
    assert sync(pid).question_prompt != nil

    # the LATE reply for Q1 lands (the worker finally returned)
    send(pid, {:__question_answered__, {:ok, :interrupted}})
    state = sync(pid)

    assert state.question_prompt != nil, "the late reply must not close the fresh Q2 dialog"
    assert [%{"question" => "Q2?"}] = state.question_prompt.questions
    assert state.status == :interrupted
  end

  test "a failed answer re-syncs: a parked question re-opens, a resolved one stays closed" do
    root = Path.join(System.tmp_dir!(), "tui-q-resync-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q-resync-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]}
      )

    # a real parked question on the session; the TUI shows the wizard
    :ok = CodingAgent.Core.Session.debug_gate(sid, [question_call()])
    wait_until(fn -> sync(pid).question_prompt != nil end)

    # the optimistic close of a failed attempt, then the refusal: the
    # parked question is re-read and the dialog comes back with a note
    agent(pid, {:status_changed, :running})
    assert sync(pid).question_prompt == nil

    send(pid, {:__question_answered__, {:error, {:not_at_question, :running}}})
    state = sync(pid)

    assert state.question_prompt != nil, "a still-parked question must re-open"
    assert [%{"question" => "Which engine?"}] = state.question_prompt.questions

    # now resolve it for real, then fail again: nothing re-opens
    {:ok, _} = CodingAgent.Core.Session.answer_question(sid, [["fd"]])

    send(pid, {:__question_answered__, {:error, {:not_at_question, :idle}}})
    state = sync(pid)

    assert state.question_prompt == nil
  end

  test "backspace deletes one GRAPHEME, also in multibyte custom answers" do
    # Regression (found live): `String.slice(buf, 0, byte_size(buf) - 1)`
    # counted bytes, so backspace was a no-op on "abä" (byte_size 4 ->
    # slice(…, 3) returns the whole string). German input hit this
    # directly.
    root = Path.join(System.tmp_dir!(), "tui-q-bs-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q-bs-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {100, 30}, session_id: sid, scope_root: root]}
      )

    :ok = CodingAgent.Core.Session.debug_gate(sid, [question_call()])
    wait_until(fn -> sync(pid).question_prompt != nil end)

    # type "abä" as a custom answer, then backspace it down
    key(pid, "0")
    key(pid, "a")
    key(pid, "b")
    key(pid, "ä")
    assert sync(pid).question_prompt.custom == "abä"

    key(pid, "backspace")
    assert sync(pid).question_prompt.custom == "ab"

    key(pid, "backspace")
    assert sync(pid).question_prompt.custom == "a"

    # at "" the next backspace closes the buffer (and re-opens the options)
    key(pid, "backspace")
    assert sync(pid).question_prompt.custom == ""
    key(pid, "backspace")
    assert sync(pid).question_prompt.custom == nil
  end

  test "the band names the pause that is actually parked" do
    # The label bug (known, recorded): `status_badge/1` only knows
    # `:interrupted` and said "approval needed (y/n/e)" for every pause —
    # a budget/doom/question pause pointed at keys that do nothing. The
    # band's label now names the parked pause.
    root = Path.join(System.tmp_dir!(), "tui-q-band-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-q-band-#{System.unique_integer()}"

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
        {Tui, [name: nil, test_mode: {110, 30}, session_id: sid, scope_root: root]}
      )

    # a question pause: the band says so
    :ok = CodingAgent.Core.Session.debug_gate(sid, [question_call()])
    wait_until(fn -> sync(pid).question_prompt != nil end)

    rows = buffer(pid)
    assert Enum.any?(rows, &String.contains?(&1, "the agent asked a question"))
    refute Enum.any?(rows, &String.contains?(&1, "approval needed"))

    # resolve it; a budget pause then names itself
    key(pid, "esc")
    wait_until(fn -> sync(pid).question_prompt == nil end)

    log =
      capture_log(fn ->
        :ok =
          CodingAgent.Core.Session.debug_gate(
            sid,
            [%{id: "b1", name: "write_file", arguments: %{"path" => "p.txt", "content" => "x"}}],
            rounds: 100
          )
      end)

    assert log =~ "tool-round budget reached: 100 (asking)"

    wait_until(fn -> sync(pid).budget_prompt != nil end)

    rows = buffer(pid)
    assert Enum.any?(rows, &String.contains?(&1, "tool budget reached (y/n)"))
    refute Enum.any?(rows, &String.contains?(&1, "approval needed"))
  end

  # The text of everything on the wire, so a test can assert what the
  # MODEL was told (the tool result is the contract, not the buffer).
  defp context_text(state) do
    state.context
    |> ReqLLM.Context.to_list()
    |> Enum.map_join("\n", fn
      %ReqLLM.Message{content: parts} when is_list(parts) ->
        Enum.map_join(parts, "", fn
          %ReqLLM.Message.ContentPart{text: t} when is_binary(t) -> t
          _ -> ""
        end)

      %ReqLLM.Message{content: t} when is_binary(t) ->
        t

      _ ->
        ""
    end)
  end
end
