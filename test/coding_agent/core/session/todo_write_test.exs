defmodule CodingAgent.Core.Session.TodoWriteTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
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

    test "the current list reaches the next request as a system block" do
      id = "todo-wire-#{System.unique_integer()}"
      start(id)

      :ok =
        Session.debug_gate(id, [
          todo_call("t1", [%{"content" => "Ship it", "status" => "in_progress"}])
        ])

      {:ok, state} = Session.state(id)
      {:ok, _model, _opts, context} = Session.wire_request(state)

      assert message_text(hd(ReqLLM.Context.to_list(context))) =~
               "- [in_progress] Ship it"
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
  end
end
