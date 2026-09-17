defmodule CodingAgent.Core.Sandbox do
  @moduledoc """
  Process confinement abstraction (ADR 015): bound the process, not the
  command text.

  A sandbox turns a shell command plus an access profile into a concrete
  executable and argv. `CodingAgent.Core.Tools.Shell` calls
  `wrap/2` at the single `Port.open/2` call site; everything that
  decides *what the process may reach* lives behind this behaviour.

  Two implementations:

    * `CodingAgent.Core.Sandbox.None` — `{:ok, "/bin/sh", ["-c", command]}`,
      i.e. today's behaviour exactly. The no-op fallback for platforms
      without an available sandbox (macOS, Windows, hardened Linux hosts).
    * `CodingAgent.Core.Sandbox.Bwrap` — bubblewrap on Linux.

  Selection mirrors `CodingAgent.Core.Providers.resolve/2`: the
  implementation is data (`:sandbox` application env), defaulting to the
  no-op so behaviour is unchanged until a sandbox is deliberately
  enabled.
  """

  @typedoc """
  The access profile for one command. `root` is the session scope root.
  The remaining keys are the coarse grants from ADR 015; an implementation
  that cannot honour a grant must refuse, never silently widen.

    * `:network` — may the process use the network (default false).
    * `:git_write` — may the process write `.git` (default false).
    * `:rw` / `:ro` / `:hide` — extra mount directives (user config).
  """
  @type profile :: %{
          required(:root) => String.t(),
          optional(:network) => boolean(),
          optional(:git_write) => boolean(),
          optional(:rw) => [String.t()],
          optional(:ro) => [String.t()],
          optional(:hide) => [String.t()]
        }

  @doc "Stable identifier for the implementation."
  @callback id() :: atom()

  @doc "Whether this implementation can run on the current machine."
  @callback available?() :: boolean()

  @doc """
  Turns a command + profile into `{executable, argv}` for `Port.open/2`.

  Returns `{:error, reason}` when the profile cannot be honoured; the
  caller must treat that as a refused call, never fall back to an
  unconfined run.
  """
  @callback wrap(command :: String.t(), profile :: profile()) ::
              {:ok, executable :: String.t(), argv :: [String.t()]} | {:error, term()}

  @default CodingAgent.Core.Sandbox.None

  @doc """
  The active sandbox implementation. Configured with the `:sandbox`
  application env; defaults to `#{inspect(@default)}` (no confinement).
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:coding_agent, :sandbox, @default)
  end

  @doc """
  Wraps `command` with the active implementation. Convenience over
  `impl/0` + `wrap/2` for the Shell call site.
  """
  @spec wrap(String.t(), profile()) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  def wrap(command, profile) when is_binary(command) and is_map(profile) do
    impl().wrap(command, profile)
  end
end
