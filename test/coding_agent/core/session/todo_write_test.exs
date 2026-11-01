defmodule CodingAgent.Core.Session.TodoWriteTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.Prompt
  alias CodingAgent.Core.Tools.TodoWrite

  @tmp_root System.tmp_dir!() |> Path.join("agent-todo-#{System.unique_integer()}")

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

  defp start(id, opts \\ []) do
    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        Keyword.merge(
          [id: id, scope_root: @tmp_root, policy: Permissions.load(nil, nil), test_mode: true],
          opts
        )
      )
  end

  defp todo_call(id, todos) do
    %{id: id, name: "todowrite", arguments: %{"todos" => todos}}
  end

  defp message_text(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t || ""
      _ -> ""
    end)
  end

  defp message_text(%ReqLLM.Message{content: c}) when is_binary(c), do: c
  defp message_text(_), do: ""

  defp context_text(state) do
    state.context |> ReqLLM.Context.to_list() |> Enum.map_join("\n", &message_text/1)
  end

  describe "the todowrite tool (ADR 031)" do
    test "is registered in the read-only class and named" do
      assert TodoWrite.name() == "todowrite"
      names = CodingAgent.Core.Tools.all(%{root: @tmp_root}) |> Enum.map(& &1.name)
      assert "todowrite" in names
    end

    test "a call stores the list and returns a summary, without pausing" do
      id = "todo-store-#{System.unique_integer()}"
      start(id)

      :ok =
        Session.debug_gate(id, [
          todo_call("t1", [
            %{"content" => "Read the code", "status" => "completed"},
            %{"content" => "Write the fix", "status" => "in_progress"}
          ])
        ])

      {:ok, state} = Session.state(id)
      # never parks at :interrupted, unlike a question (ADR 031)
      refute state.status == :interrupted

      assert state.todos == [
               %{"content" => "Read the code", "status" => "completed"},
               %{"content" => "Write the fix", "status" => "in_progress"}
             ]

      assert context_text(state) =~ "Updated the todo list (2 items, 1 open)."
    end

    test "a second call REPLACES the list (full-replace semantics)" do
      id = "todo-replace-#{System.unique_integer()}"
      start(id)

      :ok =
        Session.debug_gate(id, [todo_call("t1", [%{"content" => "A", "status" => "pending"}])])

      :ok =
        Session.debug_gate(id, [todo_call("t2", [%{"content" => "B", "status" => "pending"}])])

      {:ok, state} = Session.state(id)
      assert state.todos == [%{"content" => "B", "status" => "pending"}]
    end

    test "an empty list clears the todos" do
      id = "todo-clear-#{System.unique_integer()}"
      start(id)

      :ok =
        Session.debug_gate(id, [todo_call("t1", [%{"content" => "A", "status" => "pending"}])])

      :ok = Session.debug_gate(id, [todo_call("t2", [])])

      {:ok, state} = Session.state(id)
      assert state.todos == []
      assert context_text(state) =~ "Cleared the todo list."
    end

    test "a malformed call is an error result and changes nothing" do
      id = "todo-bad-#{System.unique_integer()}"
      start(id)

      :ok =
        Session.debug_gate(id, [
          todo_call("t1", [%{"content" => "A", "status" => "later"}])
        ])

      {:ok, state} = Session.state(id)
      assert state.todos == []
      assert context_text(state) =~ "todo `status` must be one of"
    end

    test "the current list reaches the next request on the tail, not in the prefix" do
      id = "todo-wire-#{System.unique_integer()}"
      start(id)

      :ok =
        Session.debug_gate(id, [
          todo_call("t1", [%{"content" => "Ship it", "status" => "in_progress"}])
        ])

      {:ok, state} = Session.state(id)
      {:ok, _model, _opts, context} = Session.wire_request(state)

      messages = ReqLLM.Context.to_list(context)

      # the cached prefix keeps its bytes: a todowrite must not re-prefill
      # the context (measured: 121k ≈ 2 ¢ per write when the list was in
      # the system message)
      refute message_text(hd(messages)) =~ "Ship it"
      assert message_text(List.last(messages)) =~ "- [in_progress] Ship it"
    end

    test "a todowrite sibling does not park a round with a gated call" do
      id = "todo-sibling-#{System.unique_integer()}"
      start(id, interactive: true)

      :ok =
        Session.debug_gate(id, [
          todo_call("t1", [%{"content" => "A", "status" => "pending"}]),
          %{id: "w1", name: "shell", arguments: %{"command" => "echo hi"}}
        ])

      {:ok, state} = Session.state(id)
      assert state.todos == [%{"content" => "A", "status" => "pending"}]
    end

    # The list is the only block of the per-call trailer whose size the
    # MODEL controls, and the trailer is re-sent uncached on every round —
    # so the refusal belongs here, where the model can act on it, and not
    # at request time, where the round would die before the model could
    # shrink the list it just wrote.
    test "a list too big for the trailer is refused, and the old list stays" do
      id = "todo-too-big-#{System.unique_integer()}"
      start(id)

      :ok =
        Session.debug_gate(id, [todo_call("t1", [%{"content" => "A", "status" => "pending"}])])

      huge =
        Enum.map(1..60, fn i ->
          %{"content" => String.duplicate("y", 60) <> "#{i}", "status" => "pending"}
        end)

      assert Prompt.todo_block_bytes(huge) > Prompt.todo_limit()

      :ok = Session.debug_gate(id, [todo_call("t2", huge)])

      {:ok, state} = Session.state(id)
      assert state.todos == [%{"content" => "A", "status" => "pending"}]
      assert context_text(state) =~ "the previous list is unchanged"
      assert context_text(state) =~ "limit for the list is #{Prompt.todo_limit()}"
    end

    test "the request guard refuses an over-cap trailer as a value" do
      id = "todo-cap-wire-#{System.unique_integer()}"
      start(id)

      {:ok, state} = Session.state(id)

      huge =
        Enum.map(1..60, fn i ->
          %{"content" => String.duplicate("y", 60) <> "#{i}", "status" => "pending"}
        end)

      # reach the request path without the source guard: the backstop is a
      # bug guard, and a bug guard must still be tested through the caller
      assert {:error, message} = Session.wire_request(%{state | todos: huge})
      assert message =~ "refusing the request"
      assert message =~ "limit is #{Prompt.trailer_max()}"
    end

    # The trailer's size is the one number the model never sees and the
    # human cannot otherwise get; `/stats` mirrors it from this event.
    test "the assembled trailer's size is published for the human" do
      id = "todo-trailer-#{System.unique_integer()}"
      start(id)
      :ok = Session.subscribe(id)

      :ok =
        Session.debug_gate(id, [todo_call("t1", [%{"content" => "A", "status" => "pending"}])])

      {:ok, state} = Session.state(id)
      {:ok, _input, _opts, ctx} = Session.wire_request(state)

      expected = Prompt.trailer_bytes(ctx)
      assert expected > 0
      assert_receive {:agent, ^id, {:trailer_bytes, ^expected}}, 1_000
    end

    # Review N141: the list is DURABLE, so it can arrive from the store or a
    # mount option — paths that never pass `apply_todos/2`. A session carrying
    # one that predates the cap used to have EVERY round refused, and the
    # write that could shrink it needed a round: a deadlock. The list is
    # fitted where it enters now, and the human is told what went.
    test "an over-cap list from outside the tool does not make the session unusable" do
      id = "todo-persisted-#{System.unique_integer()}"

      huge =
        Enum.map(1..40, fn i ->
          %{"content" => String.duplicate("y", 60) <> "#{i}", "status" => "pending"}
        end)

      start(id, todos: huge)

      {:ok, state} = Session.state(id)

      # fitted, not refused — and the model reads the list it can update
      assert length(state.todos) < 40
      assert Prompt.todo_block_bytes(state.todos) <= Prompt.todo_limit()

      # the request the deadlock was about now assembles
      assert {:ok, _model, _opts, ctx} = Session.wire_request(state)
      assert Prompt.trailer_bytes(ctx) <= Prompt.trailer_max()

      # and the human is told what the fit took
      assert Enum.any?(
               CodingAgent.Core.Session.Store.display(id),
               &(to_string(&1.text) =~ "dropped")
             )
    end
  end

  describe "TodoWrite.parse/1" do
    test "accepts string and atom keys" do
      assert {:ok, [%{"content" => "A", "status" => "pending"}]} =
               TodoWrite.parse(%{todos: [%{content: "A", status: "pending"}]})
    end

    test "flattens multi-line content to one line" do
      assert {:ok, [%{"content" => "one two", "status" => "pending"}]} =
               TodoWrite.parse(%{"todos" => [%{"content" => "one\ntwo", "status" => "pending"}]})
    end

    test "rejects a missing list, an empty content, and an unknown status" do
      assert {:error, _} = TodoWrite.parse(%{})

      assert {:error, _} =
               TodoWrite.parse(%{"todos" => [%{"content" => " ", "status" => "pending"}]})

      assert {:error, _} =
               TodoWrite.parse(%{"todos" => [%{"content" => "A", "status" => "nope"}]})
    end

    test "caps the list length and per-item content (review: no ceiling)" do
      too_many =
        Enum.map(1..65, fn i -> %{"content" => "t#{i}", "status" => "pending"} end)

      assert {:error, reason} = TodoWrite.parse(%{"todos" => too_many})
      assert reason =~ "too many todos"

      long = [%{"content" => String.duplicate("x", 501), "status" => "pending"}]
      assert {:error, reason} = TodoWrite.parse(%{"todos" => long})
      assert reason =~ "too long"

      # a large-but-legal list is accepted
      ok = Enum.map(1..64, fn i -> %{"content" => "t#{i}", "status" => "pending"} end)
      assert {:ok, todos} = TodoWrite.parse(%{"todos" => ok})
      assert length(todos) == 64
    end

    test "carries agent-private notes, trimmed but not flattened" do
      assert {:ok, [todo]} =
               TodoWrite.parse(%{
                 "todos" => [
                   %{"content" => "A", "status" => "pending", "notes" => "  line1\nline2  "}
                 ]
               })

      assert todo["notes"] == "line1\nline2"
    end

    test "a blank note is dropped, so an item keeps its minimal shape" do
      assert {:ok, [todo]} =
               TodoWrite.parse(%{
                 "todos" => [%{"content" => "A", "status" => "pending", "notes" => "   "}]
               })

      refute Map.has_key?(todo, "notes")
    end

    test "rejects a non-string note and caps per-item and total notes size" do
      assert {:error, reason} =
               TodoWrite.parse(%{
                 "todos" => [%{"content" => "A", "status" => "pending", "notes" => 42}]
               })

      assert reason =~ "must be a string"

      long = [%{"content" => "A", "status" => "pending", "notes" => String.duplicate("x", 1001)}]

      assert {:error, reason} = TodoWrite.parse(%{"todos" => long})
      assert reason =~ "notes"
      # the cap names what was actually written, so one bounce is enough
      assert reason =~ "limit 1000 chars, you wrote 1001"

      # total cap across items
      many =
        Enum.map(1..20, fn i ->
          %{"content" => "t#{i}", "status" => "pending", "notes" => String.duplicate("y", 500)}
        end)

      assert {:error, reason} = TodoWrite.parse(%{"todos" => many})
      assert reason =~ "in total"
      assert reason =~ "you wrote 10000"
    end

    test "a 589-char note is accepted (review: the cap bounced a legitimate note)" do
      note = String.duplicate("x", 589)

      assert {:ok, [todo]} =
               TodoWrite.parse(%{
                 "todos" => [%{"content" => "A", "status" => "pending", "notes" => note}]
               })

      assert todo["notes"] == note
    end

    test "a max-length note is accepted per item, and eight of them fit the total" do
      note = String.duplicate("x", 1000)

      assert {:ok, [todo]} =
               TodoWrite.parse(%{
                 "todos" => [%{"content" => "A", "status" => "pending", "notes" => note}]
               })

      assert todo["notes"] == note

      eight =
        Enum.map(1..8, fn i ->
          %{"content" => "t#{i}", "status" => "pending", "notes" => note}
        end)

      assert {:ok, todos} = TodoWrite.parse(%{"todos" => eight})
      assert length(todos) == 8

      nine = eight ++ [%{"content" => "t9", "status" => "pending", "notes" => note}]
      assert {:error, reason} = TodoWrite.parse(%{"todos" => nine})
      assert reason =~ "in total"
    end
  end
end
