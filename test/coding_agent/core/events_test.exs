defmodule CodingAgent.Core.EventsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Events

  # CodingAgent.EventRegistry is started by the application supervision
  # tree (the test app is running); no per-test registry needed.

  test "publish/2 delivers {:agent, id, event} to every subscriber under the key" do
    session = "ev-#{System.unique_integer([:positive])}"

    Registry.register(CodingAgent.EventRegistry, {Events.key(), session}, nil)
    Registry.register(CodingAgent.EventRegistry, {Events.key(), session}, nil)

    assert :ok = Events.publish(session, {:info, "hi"})

    assert_receive {:agent, ^session, {:info, "hi"}}
    assert_receive {:agent, ^session, {:info, "hi"}}
  end

  test "unregister-then-register delivers once (the subscribe/1 contract)" do
    # `Session.subscribe/1` makes this call pair so a re-subscribing caller
    # (the TUI re-mounts on a session switch) keeps ONE entry: `register`
    # alone is a no-op when the key is already there, so without the
    # unregister the second mount would double every event (N95). This
    # pins the mechanism the fix relies on, next to the test above that
    # shows what happens WITHOUT it.
    session = "ev-#{System.unique_integer([:positive])}"
    key = {Events.key(), session}

    Registry.register(CodingAgent.EventRegistry, key, nil)
    Registry.unregister(CodingAgent.EventRegistry, key)
    Registry.register(CodingAgent.EventRegistry, key, nil)

    assert :ok = Events.publish(session, {:info, "once"})

    assert_receive {:agent, ^session, {:info, "once"}}
    refute_received {:agent, ^session, {:info, "once"}}
  end

  test "publish/2 is a no-op with no subscribers" do
    assert :ok = Events.publish("nobody", {:info, "x"})
    refute_received {:agent, _, _}
  end

  test "publish/2 does not cross session boundaries" do
    Registry.register(CodingAgent.EventRegistry, {Events.key(), "a"}, nil)

    :ok = Events.publish("b", {:info, "for-b"})
    refute_received {:agent, _, _}

    :ok = Events.publish("a", {:info, "for-a"})
    assert_receive {:agent, "a", {:info, "for-a"}}
  end
end
