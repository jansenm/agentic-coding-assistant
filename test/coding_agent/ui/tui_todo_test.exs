defmodule CodingAgent.UI.TuiTodoTest do
  @moduledoc """
  The sidebar's TODO block (ADR 031): the model's list is mirrored from
  `{:todos_updated, todos}` and from the session on mount, rendered one
  row per item, capped when long.
  """
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.UI.Tui

  defp start_tui(size \\ {100, 30}, opts \\ []) do
    start_supervised!(%{
      id: String.to_atom("tui-todo-#{System.unique_integer([:positive])}"),
      start: {Tui, :start_link, [[name: nil, test_mode: size, scope_root: File.cwd!()] ++ opts]}
    })
  end

  test "an empty list paints no TODO block" do
    pid = start_tui()
    fire(pid, :__resize_poll__)

    refute Enum.join(buffer(pid), "\n") =~ "todo"
  end

  test "a todos_updated event paints the block with the item contents" do
    pid = start_tui()
    fire(pid, :__resize_poll__)

    agent(
      pid,
      {:todos_updated,
       [
         %{"content" => "Read the code", "status" => "completed"},
         %{"content" => "Write the fix", "status" => "in_progress"}
       ]}
    )

    assert sync(pid).todos != []
    text = Enum.join(buffer(pid), "\n")
    assert text =~ "todo"
    assert text =~ "Read the code"
    assert text =~ "Write the fix"
  end

  test "a long list is capped with an overflow line" do
    pid = start_tui()
    fire(pid, :__resize_poll__)

    todos = for i <- 1..12, do: %{"content" => "item #{i}", "status" => "pending"}

    agent(pid, {:todos_updated, todos})

    text = Enum.join(buffer(pid), "\n")
    assert text =~ "item 1"
    refute text =~ "item 12"
    assert text =~ "+4 more"
  end

  test "a mounted session seeds the list from its stored todos" do
    root = Path.join(System.tmp_dir!(), "tui-todo-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    sid = "tui-todo-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: sid,
        scope_root: root,
        policy: Permissions.load(nil, nil),
        test_mode: true
      )

    # store a list through the real interception, then mount the TUI: the
    # mount seeds from `Session.state/1`
    :ok =
      Session.debug_gate(sid, [
        %{
          id: "t1",
          name: "todowrite",
          arguments: %{"todos" => [%{"content" => "Seeded", "status" => "pending"}]}
        }
      ])

    pid = start_tui({100, 30}, session_id: sid, scope_root: root)
    fire(pid, :__resize_poll__)

    assert sync(pid).todos == [%{"content" => "Seeded", "status" => "pending"}]
    assert Enum.join(buffer(pid), "\n") =~ "Seeded"
  end
end
