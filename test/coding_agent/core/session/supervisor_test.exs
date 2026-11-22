# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.SupervisorTest do
  @moduledoc """
  The restart policy for sessions (review N86, ADR 047).

  Both tests drive the REAL `CodingAgent.Core.Session.Supervisor` the app
  starts, because the property under test is a property of that supervisor's
  child spec — not of a hand-built one. They kill processes on purpose; the
  sessions they create are their own, and every assertion is about what the
  supervisor did (or refused to do) afterwards.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.{Store, Supervisor}

  # A run-scoped root: the tests start REAL sessions in the app supervisor,
  # and a session outlives the test that started it. Deleting the root under
  # one makes a later port's `{:cd, root}` fail and erl_child_setup print
  # "spawn: Could not cd to …" on the VM's stderr (review N122, form 1).
  # The run TMPDIR owns the tree, so this module never removes it.
  setup_all do
    {:ok, root: CodingAgent.TestScope.root!("session-sup")}
  end

  defp start(id, root) do
    {:ok, pid} =
      Supervisor.start_session(
        id: id,
        scope_root: root,
        model: "ollama:test-model",
        test_mode: true,
        interactive: true
      )

    pid
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "a crashed session is not restarted (ADR 047)" do
    test "the process stays gone and the last persisted state is what remains", %{root: root} do
      id = unique("n86-gone")
      pid = start(id, root)

      # A conversation on disk, written the way a turn boundary writes it,
      # plus a model switch: two facts the START OPTIONS do not carry.
      {:ok, state} = Session.state(id)

      context =
        Enum.reduce(1..3, state.context, fn i, acc ->
          acc
          |> ReqLLM.Context.append(ReqLLM.Context.user("question #{i}"))
          |> ReqLLM.Context.append(ReqLLM.Context.assistant("answer #{i}"))
        end)

      :ok = Store.save(%{state | context: context, model: "ollama:switched-model"})

      Process.exit(pid, :kill)

      # No impostor: the registry entry is gone, every call degrades.
      assert :ok = await_gone(id)
      assert {:error, :not_found} = Session.state(id)

      # The store still holds the conversation and the switch. Under the
      # old `:transient` spec the restarted process held `Context.new()`
      # and the configured start model, and its next boundary wrote that
      # over this row (measured: 7 messages -> 1).
      assert {:ok, persisted} = Store.load(id)
      assert persisted.model == "ollama:switched-model"
      assert length(persisted.context.messages) == length(context.messages)
    end

    test "a normal stop is not restarted either (the subagent seam)", %{root: root} do
      id = unique("n86-stop")
      _pid = start(id, root)

      :ok = Session.stop(id)

      assert :ok = await_gone(id)
      assert {:error, :not_found} = Session.state(id)
    end
  end

  describe "the blast radius of a crash" do
    test "four deaths do not take the session supervisor or a bystander down", %{root: root} do
      # OTP's default intensity is 3 restarts / 5 s, applied to the
      # children of a DynamicSupervisor as a GROUP: under `:transient`
      # four crashes of one session killed the supervisor and every other
      # live session with it. Measured before the fix, in this same
      # application: `:shutdown`, bystander dead, parent rebuilt an empty
      # supervisor.
      supervisor = Process.whereis(Supervisor)
      assert is_pid(supervisor)

      bystander_id = unique("n86-bystander")
      bystander = start(bystander_id, root)

      for _ <- 1..4 do
        doomed = unique("n86-doomed")
        Process.exit(start(doomed, root), :kill)
        Process.sleep(50)
      end

      assert Process.whereis(Supervisor) == supervisor
      assert Process.alive?(bystander)
      assert {:ok, _state} = Session.state(bystander_id)

      # and the supervisor still accepts work
      assert is_pid(start(unique("n86-after"), root))
    end
  end

  # The death is asynchronous: poll the registry rather than sleeping.
  defp await_gone(id, attempts \\ 100) do
    cond do
      Registry.lookup(CodingAgent.Registry, {:session, id}) == [] ->
        :ok

      attempts == 0 ->
        flunk("session #{id} never left the registry")

      true ->
        Process.sleep(10)
        await_gone(id, attempts - 1)
    end
  end
end
