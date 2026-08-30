defmodule CodingAgentTest do
  use ExUnit.Case, async: true

  test "model config is readable" do
    assert is_binary(CodingAgent.model())
    assert String.contains?(CodingAgent.model(), ":")
  end

  test "supervision tree starts with the registry" do
    pid = GenServer.whereis(CodingAgent.Registry)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end
end