defmodule CodingAgent.Core.Sandbox.None do
  @moduledoc """
  No confinement: run the command through `/bin/sh` exactly as the Shell
  tool always did.

  ADR 030: this is a **test seam and an explicit opt-out**, never an
  automatic fallback. Session start requires a confining sandbox, so a
  session only runs under `None` when a test selects it deliberately
  (`config/test.exs` pins a confining double; `None` appears where the
  refusal path or the no-op itself is under test).

  The one grant it must REFUSE is `root_ro`: it cannot make the scope
  read-only, and silently running read-write would let a read-only agent
  bypass its own file-tool deny (`echo > f`). Refusing is the safe
  direction — the call fails, it does not widen.
  """

  @behaviour CodingAgent.Core.Sandbox

  @impl true
  def id, do: :none

  @impl true
  def available?, do: true

  @impl true
  def confines?, do: false

  @impl true
  def wrap({:shell, command}, profile) when is_binary(command) do
    refuse_root_ro(profile, fn -> {:ok, "/bin/sh", ["-c", command]} end)
  end

  def wrap({:exec, file, args}, profile) when is_binary(file) and is_list(args) do
    refuse_root_ro(profile, fn ->
      # Port.open needs an absolute path; resolve via PATH like a shell would.
      case System.find_executable(file) do
        nil -> {:error, {:executable_not_found, file}}
        exe -> {:ok, exe, args}
      end
    end)
  end

  # `{:stdin, count, spec}` (ADR 030): the same shell pipeline the
  # confining implementations use, so the file tools behave identically
  # under the test seam.
  def wrap({:stdin, count, spec} = _inner, profile) when is_integer(count) and count >= 0 do
    refuse_root_ro(profile, fn -> CodingAgent.Core.Sandbox.stdin_command(count, spec) end)
  end

  defp refuse_root_ro(%{root_ro: true}, _fun), do: {:error, :root_ro_unavailable}
  defp refuse_root_ro(_profile, fun), do: fun.()
end
