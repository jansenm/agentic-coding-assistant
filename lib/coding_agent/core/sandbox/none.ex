defmodule CodingAgent.Core.Sandbox.None do
  @moduledoc """
  No confinement: run the command through `/bin/sh` exactly as the Shell
  tool has always done.

  This is the default (ADR 015) so that behaviour is unchanged on
  platforms where no sandbox is available — macOS, Windows, CI without
  unprivileged user namespaces, and hardened Linux hosts. It is a
  deliberate no-op, not a stub: there is nothing to honour, and the
  permission gate remains the only boundary, as before.
  """

  @behaviour CodingAgent.Core.Sandbox

  @impl true
  def id, do: :none

  @impl true
  def available?, do: true

  @impl true
  def confines?, do: false

  @impl true
  def wrap(command, _profile) when is_binary(command) do
    {:ok, "/bin/sh", ["-c", command]}
  end
end
