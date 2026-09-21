defmodule CodingAgent.Core.ToolStartedEventTest do
  @moduledoc """
  `{:tool_started, name}` is broadcast BEFORE a tool runs (Track B).

  Tools run synchronously on the worker, so without a start event the UI
  cannot say "running mix" — it only learns a tool existed when its
  result lands. This pins the ordering: start before execute/result.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.Supervisor

  @tmp_root System.tmp_dir!() |> Path.join("tool-started-#{System.unique_integer()}")

  setup do
    File.mkdir_p!(@tmp_root)
    File.write!(Path.join(@tmp_root, "target.txt"), "hello")
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  test "tool_started arrives before tool_executed" do
    id = "tool-started-#{System.unique_integer()}"

    {:ok, _} =
      Supervisor.start_session(id: id, scope_root: @tmp_root, test_mode: true)

    :ok = Session.subscribe(id)

    :ok =
      Session.debug_gate(id, [
        %{id: "c1", name: "read_file", arguments: %{"path" => "target.txt"}}
      ])

    # drain the mailbox; collect the tool events in arrival order
    events = collect_tool_events([])

    assert {:tool_started, "read_file"} in events,
           "no tool_started in #{inspect(events)}"

    started = Enum.find_index(events, &(&1 == {:tool_started, "read_file"}))

    executed =
      Enum.find_index(events, fn
        {:tool_executed, "read_file", _, _} -> true
        _ -> false
      end)

    assert executed != nil, "no tool_executed in #{inspect(events)}"
    assert started < executed, "tool_started must precede tool_executed"
  end

  test "tool_executed carries the call arguments, recorded in the display view" do
    # the display view must say WHAT a tool was asked to do, not just its
    # output — otherwise an exported transcript cannot name the file read
    id = "tool-args-#{System.unique_integer()}"

    {:ok, _} =
      Supervisor.start_session(id: id, scope_root: @tmp_root, test_mode: true)

    :ok = Session.subscribe(id)

    :ok =
      Session.debug_gate(id, [
        %{id: "c1", name: "read_file", arguments: %{"path" => "target.txt"}}
      ])

    # the event carries the arguments
    assert_receive {:agent, {:tool_executed, "read_file", _content, args}}, 1_000
    assert args == %{"path" => "target.txt"}

    # and they are persisted on the display row
    assert [%{kind: :tool, meta: {:tool, "read_file", %{"path" => "target.txt"}}}] =
             CodingAgent.Core.Session.Store.display(id)
  end

  defp collect_tool_events(acc) do
    receive do
      {:agent, {:tool_started, _} = ev} -> collect_tool_events([ev | acc])
      {:agent, {:tool_executed, _, _, _} = ev} -> collect_tool_events([ev | acc])
      {:agent, _other} -> collect_tool_events(acc)
    after
      200 -> Enum.reverse(acc)
    end
  end
end
