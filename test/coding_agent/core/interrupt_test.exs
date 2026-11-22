# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.InterruptTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Interrupt

  # each test uses its own id so the shared named ETS table stays clean
  defp uniq, do: "interrupt-#{System.unique_integer([:positive])}"

  describe "flags" do
    test "request/1 raises the flag; clear/1 drops it" do
      id = uniq()
      refute Interrupt.requested?(id)

      assert :ok = Interrupt.request(id)
      assert Interrupt.requested?(id)

      assert :ok = Interrupt.clear(id)
      refute Interrupt.requested?(id)
    end

    test "request/1 is idempotent" do
      id = uniq()
      assert :ok = Interrupt.request(id)
      assert :ok = Interrupt.request(id)
      assert Interrupt.requested?(id)
      Interrupt.clear(id)
    end

    test "snapshot/1 reports the flag and whether a cancel is registered" do
      id = uniq()
      assert %{requested?: false, at: nil, cancelling?: false} = Interrupt.snapshot(id)

      Interrupt.register(id, fn -> :ok end)
      Interrupt.request(id)

      snap = Interrupt.snapshot(id)
      assert snap.requested?
      assert is_integer(snap.at)
      assert snap.cancelling?

      Interrupt.clear(id)
      assert %{requested?: false} = Interrupt.snapshot(id)
    end
  end

  describe "active-stream cancel" do
    test "request/1 fires the registered cancel closure" do
      id = uniq()
      test_pid = self()

      Interrupt.register(id, fn -> send(test_pid, :cancelled) end)
      assert :ok = Interrupt.request(id)

      assert_receive :cancelled, 1_000
      # the handler stays registered until unregistered/cleared, so a
      # repeat request fires it again — harmless, StreamResponse.close/1
      # is idempotent
      assert :ok = Interrupt.request(id)
      assert_receive :cancelled, 1_000

      Interrupt.clear(id)
    end

    test "a raising cancel closure does not take the caller down" do
      id = uniq()

      Interrupt.register(id, fn -> raise "cancel blew up" end)
      assert :ok = Interrupt.request(id)

      # still healthy and readable
      assert Interrupt.requested?(id)
      Interrupt.clear(id)
    end

    test "unregister/1 drops the handle so request/1 does not fire it" do
      id = uniq()
      test_pid = self()

      Interrupt.register(id, fn -> send(test_pid, :cancelled) end)
      Interrupt.unregister(id)
      Interrupt.request(id)

      refute_receive :cancelled, 100
      Interrupt.clear(id)
    end
  end
end
