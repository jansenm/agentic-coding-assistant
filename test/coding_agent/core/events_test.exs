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
