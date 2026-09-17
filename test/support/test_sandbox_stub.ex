defmodule CodingAgent.TestSandbox.Stub do
  @moduledoc """
  Test sandbox double: confines and is available. `wrap/2` returns a fixed
  argv so the gate's auto-run path can be exercised without a real bwrap.
  Lives in test/support (a compiled module) on purpose: the sandbox
  resolver loads modules to inspect them, and an in-memory nested stub is
  not discoverable that way.
  """

  @behaviour CodingAgent.Core.Sandbox

  @impl true
  def id, do: :test_stub

  @impl true
  def available?, do: true

  @impl true
  def confines?, do: true

  @impl true
  def check, do: :ok

  @impl true
  def wrap({:shell, command}, _profile), do: {:ok, "/bin/sh", ["-c", command]}
  def wrap({:exec, file, args}, _profile), do: {:ok, file, args}
end
