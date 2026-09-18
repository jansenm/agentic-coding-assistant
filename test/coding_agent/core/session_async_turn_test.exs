defmodule CodingAgent.Core.Session.AsyncTurnTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.State

  @tmp_root System.tmp_dir!() |> Path.join("agent-async-#{System.unique_integer([:positive])}")

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

  # A session whose turn worker blocks until released, so a test can hold
  # a turn "in flight" without a provider. `release` is a function that
  # waits for the test to send the go-ahead.
  defp start_held(id, opts \\ []) do
    parent = self()

    runner = fn state ->
      send(parent, {:worker_started, self()})

      receive do
        :release -> {state, {:ok, %{state | status: :idle}}}
      after
        5_000 -> {state, {:error, :never_released}}
      end
    end

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        Keyword.merge(
          [id: id, scope_root: @tmp_root, test_mode: false, turn_runner: runner],
          opts
        )
      )
  end

  defp release(worker_pid), do: send(worker_pid, :release)

  test "state/1 answers promptly while a turn is in flight" do
    id = "async-state-#{System.unique_integer()}"
    start_held(id)

    task = Task.async(fn -> Session.run(id, "hello") end)
    assert_receive {:worker_started, worker}, 1_000

    # the old design would block here until the turn finished; the whole
    # point is that this returns now
    assert {:ok, %State{status: :running}} = Session.state(id)

    release(worker)
    assert {:ok, %State{status: :idle}} = Task.await(task, 2_000)
  end

  test "set_agent/2 answers while a turn is in flight and applies at the boundary" do
    id = "async-set-agent-#{System.unique_integer()}"
    start_held(id, agent: "build")

    task = Task.async(fn -> Session.run(id, "hello") end)
    assert_receive {:worker_started, worker}, 1_000

    # idle-answering is the regression: this call used to freeze until
    # the stream ended
    assert {:ok, %State{agent: %{name: "build"}}} = Session.set_agent(id, "plan")

    release(worker)
    assert {:ok, _} = Task.await(task, 2_000)

    # the switch lands for the NEXT turn, not the one in flight
    assert {:ok, %State{agent: %{name: "plan"}}} = Session.state(id)
  end

  test "a turn that arrives mid-flight queues and runs after the current one" do
    id = "async-queue-#{System.unique_integer()}"
    start_held(id)

    first = Task.async(fn -> Session.run(id, "first") end)
    assert_receive {:worker_started, worker1}, 1_000

    second = Task.async(fn -> Session.run(id, "second") end)

    release(worker1)
    assert_receive {:worker_started, worker2}, 1_000

    release(worker2)
    assert {:ok, %State{status: :idle}} = Task.await(first, 2_000)
    assert {:ok, %State{status: :idle}} = Task.await(second, 2_000)
  end

  # the crash path logs by design (`turn worker crashed` + the Task
  # report) — capture it so the intentional boom does not look like a
  # test failure in the run output
  @tag capture_log: true
  test "a crashing worker fails the turn instead of hanging the caller" do
    id = "async-crash-#{System.unique_integer()}"

    runner = fn _state -> raise "provider stack boom" end

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: id,
        scope_root: @tmp_root,
        test_mode: false,
        turn_runner: runner
      )

    assert {:error, {:turn_worker_exit, _}} = Session.run(id, "boom")

    assert {:ok, %State{status: :error}} = Session.state(id)
  end
end
