defmodule CodingAgent.Core.Sandbox.None do
  @moduledoc """
  No confinement: run the command through `/bin/sh` exactly as the Shell
  tool has always done.

  This is the default (ADR 015) so that behaviour is unchanged on
  platforms where no sandbox is available — macOS, Windows, CI without
  unprivileged user namespaces, and hardened Linux hosts. It is a
  deliberate no-op, not a stub: there is nothing to honour, and the
  permission gate remains the only boundary, as before.

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

  defp refuse_root_ro(%{root_ro: true}, _fun), do: {:error, :root_ro_unavailable}
  defp refuse_root_ro(_profile, fun), do: fun.()
end
