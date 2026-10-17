defmodule CodingAgent.TestSandbox.Stub do
  @moduledoc """
  Test sandbox double: confines and is available. `wrap/2` returns a fixed
  argv so the gate's auto-run path can be exercised without a real bwrap.
  Lives in test/support (a compiled module) on purpose: the sandbox
  resolver loads modules to inspect them, and an in-memory nested stub is
  not discoverable that way.

  ADR 030 makes this the suite's default (`config/test.exs`): every test
  session needs a *confining* sandbox, and this double claims to confine
  without the host dependency. It does NOT actually confine — tests that
  assert real confinement semantics live in the bwrap integration tests
  (self-skipping).
  """

  @behaviour CodingAgent.Core.Sandbox

  @impl true
  def id, do: :test_stub

  @impl true
  def available?, do: true

  @impl true
  def check, do: :ok

  @impl true
  def wrap({:shell, command}, _profile), do: {:ok, "/bin/sh", ["-c", command]}

  # Port.open needs an absolute path, resolved from PATH exactly as a
  # shell would; a bare "git" must not reach the port.
  def wrap({:exec, file, args}, _profile) do
    case System.find_executable(file) do
      nil -> {:error, {:executable_not_found, file}}
      exe -> {:ok, exe, args}
    end
  end

  # `{:stdin, count, spec}`: the unconfined shell pipeline (ADR 030), so
  # file-tool behaviour is the same under the seam.
  def wrap({:stdin, count, spec}, _profile) when is_integer(count) and count >= 0 do
    CodingAgent.Core.Sandbox.stdin_command(count, spec)
  end
end
