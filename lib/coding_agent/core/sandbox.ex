# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Sandbox do
  @moduledoc """
  Process confinement abstraction (ADR 015): bound the process, not the
  command text.

  A sandbox turns a shell command plus an access profile into a concrete
  executable and argv. `CodingAgent.Core.Tools.Shell` calls
  `wrap/2` at the single `Port.open/2` call site; everything that
  decides *what the process may reach* lives behind this behaviour.

  `CodingAgent.Core.Sandbox.Bwrap` (bubblewrap) is the shipped Linux
  implementation; other platforms bring their own. The test run uses a
  confining double (`CodingAgent.TestSandbox.Stub`, `config/test.exs`).

  Confinement is a **precondition, not a capability to query** (ADR 030):
  every implementation confines, and a session only starts when a usable
  one is configured. Selection mirrors `CodingAgent.Core.Providers.resolve/2`:
  the implementation is data (`:sandbox` application env). When the
  configured implementation cannot run on this machine there is **no
  fallback to an unconfined run**: `wrap/2` returns
  `{:error, {:sandbox_unavailable, reason}}`, `diagnose/0` reports why,
  and a session refuses to start (`refusal_message/0`).
  """

  @typedoc """
  The access profile for one command. `root` is the session scope root.
  The remaining keys are the coarse grants from ADR 015; an implementation
  that cannot honour a grant must refuse, never silently widen.

    * `:network` — may the process use the network (default false).
    * `:change_vcs` — may the process change the repository's version
      control state: the git index, objects and refs (default false). The
      working tree is already writable — this grant is about the VCS
      metadata, which for a linked worktree or a subdirectory session
      lives OUTSIDE the scope root and is bound read-only by default.
    * `:root_ro` — bind the scope root READ-ONLY (default false). An agent
      with only read tools sets this so `shell` cannot bypass the file-tool
      deny (`echo > f`). An implementation that cannot make the root
      read-only must REFUSE it, never silently run read-write.
    * `:scratch` — a host directory to bind over `/tmp` for the session
      (ADR 022); `nil` keeps the per-call tmpfs, so a scope without a
      session id is unchanged.
    * `:rw` / `:ro` / `:hide` — extra mount directives (user config).
  """
  @type profile :: %{
          required(:root) => String.t(),
          optional(:network) => boolean(),
          optional(:change_vcs) => boolean(),
          optional(:root_ro) => boolean(),
          optional(:session_id) => String.t() | nil,
          optional(:scratch) => String.t() | nil,
          optional(:rw) => [String.t()],
          optional(:ro) => [String.t()],
          optional(:hide) => [String.t()]
        }

  # A command spec the sandbox knows how to launch.
  #
  #   * {:shell, command}   — run `command` through a shell (`shell` tool).
  #   * {:exec, file, args} — run `file` with `args` directly, no shell
  #     (the `git` tool). This matters: joining a list of agent arguments
  #     into a shell string would make them injectable (`["-m", "x; rm
  #     -rf /"]`), so the sandbox must not introduce a shell around a
  #     list that was never one.
  #   * {:stdin, count, spec} — feed exactly `count` bytes to the inner
  #     spec's standard input (ADR 030: `write_file` writes through a
  #     confined process). A port cannot signal EOF, so the wrapper pipes
  #     `{ head -c <count>; }` into the inner command: the reader exits
  #     after exactly `count` bytes, which closes the pipe and gives the
  #     inner process its EOF. `count` is an integer we computed, never
  #     agent input.
  @type spec ::
          {:shell, String.t()}
          | {:exec, String.t(), [String.t()]}
          | {:stdin, non_neg_integer(), spec()}

  @doc false
  # The unconfined stdin wrapper the test double shares: a shell pipeline
  # feeding exactly `count` bytes, then closing
  # the pipe (that close is the inner process's EOF). The exec form keeps
  # its argv as positional parameters, so a path with spaces or quotes is
  # never re-parsed by the shell.
  @spec stdin_command(non_neg_integer(), spec()) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  def stdin_command(count, {:shell, command}) when is_binary(command) do
    {:ok, "/bin/sh", ["-c", "head -c #{count} | " <> command]}
  end

  def stdin_command(count, {:exec, file, args}) when is_binary(file) and is_list(args) do
    case System.find_executable(file) do
      nil -> {:error, {:executable_not_found, file}}
      exe -> {:ok, "/bin/sh", ["-c", ~s(head -c #{count} | exec "$@"), "sh", exe | args]}
    end
  end

  @doc "Stable identifier for the implementation."
  @callback id() :: atom()

  @doc "Whether this implementation can run on the current machine."
  @callback available?() :: boolean()

  @doc """
  Optional: a functional probe with a reason, used by `diagnose/0` at
  startup for a human-readable message. A confining implementation should
  provide it; the no-op need not.
  """
  @callback check() :: :ok | {:error, String.t()}

  @optional_callbacks check: 0, visible_path: 2

  @doc """
  The path a confined process sees for a host path, given the profile — the
  inverse of the mounts `wrap/2` sets up. Optional: the default is the
  identity, so an implementation that does not remap the host filesystem
  reports the host path unchanged.

  The one shipped remap is the session scratch bound over `/tmp` (ADR 022):
  `Bwrap` maps `<scratch>/x` to `/tmp/x`. A caller that must hand a host file
  to a confined process (the checkpoint temp index, ADR 036) asks here
  instead of hardcoding `/tmp`, so a platform sandbox that binds differently
  — or not at all — stays correct.
  """
  @callback visible_path(host_path :: String.t(), profile()) :: String.t()

  @doc """
  Turns a command spec + profile into `{executable, argv}` for
  `Port.open/2`.

  Returns `{:error, reason}` when the profile cannot be honoured; the
  caller must treat that as a refused call, never fall back to an
  unconfined run.
  """
  @callback wrap(spec(), profile()) ::
              {:ok, executable :: String.t(), argv :: [String.t()]} | {:error, term()}

  @default CodingAgent.Core.Sandbox.Bwrap

  @doc """
  The module the user configured with the `:sandbox` application env
  (default `#{inspect(@default)}`). This is what was *asked for*; use
  `impl/0` for what will actually run.
  """
  @spec configured() :: module()
  def configured do
    Application.get_env(:coding_agent, :sandbox, @default)
  end

  @doc """
  The effective sandbox implementation, or `nil` when the configured one
  cannot run on this machine.

  ADR 030 removed the fallback to an unconfined run: an unavailable
  implementation yields `nil`, so callers must refuse rather than run
  unconfined.
  """
  @spec impl() :: module() | nil
  def impl do
    module = configured()
    if usable_module?(module), do: module
  end

  defp usable_module?(module) when is_atom(module) and not is_nil(module) do
    # An implementation must prove it works on this machine.
    if exports?(module, :available?, 0), do: module.available?(), else: true
  end

  defp usable_module?(_), do: false

  # `function_exported?/3` does not load a module, and `Code.ensure_loaded?/1`
  # only succeeds for modules on the code path — but an in-memory module (a
  # test stub) is already loaded and must be seen. Ask loaded-first, then try
  # to load.
  defp exports?(module, fun, arity) do
    (module_loaded?(module) or Code.ensure_loaded?(module)) and
      function_exported?(module, fun, arity)
  end

  defp module_loaded?(module), do: :erlang.module_loaded(module) != false

  @doc """
  The sandbox-visible path for `host_path` under `profile`. Delegates to the
  effective implementation; an implementation without the optional callback
  — or an unusable configuration — reports the host path.
  """
  @spec visible_path(String.t(), profile()) :: String.t()
  def visible_path(host_path, profile) do
    case impl() do
      nil ->
        host_path

      impl ->
        if exports?(impl, :visible_path, 2),
          do: impl.visible_path(host_path, profile),
          else: host_path
    end
  end

  @doc """
  A startup diagnostic for the configured sandbox: `:ok` when it works,
  `{:error, reason}` when the implementation cannot run on this machine,
  with a human-readable reason.
  """
  @spec diagnose() :: :ok | {:error, String.t()}
  def diagnose do
    module = configured()

    cond do
      not is_atom(module) or is_nil(module) ->
        {:error, "invalid :sandbox configuration: #{inspect(module)}"}

      exports?(module, :check, 0) ->
        module.check()

      true ->
        :ok
    end
  end

  @doc """
  The message a session start refuses with when no usable sandbox is
  configured (ADR 030). Names the missing piece and the way out.
  """
  @spec refusal_message() :: String.t()
  def refusal_message do
    reason =
      case diagnose() do
        :ok -> "no usable sandbox implementation is configured"
        {:error, reason} -> reason
      end

    "no usable sandbox: #{reason}. " <>
      "Install bubblewrap and enable unprivileged user namespaces."
  end

  @doc """
  Wraps `command` as a shell command with the active implementation.
  Refuses (`{:error, {:sandbox_unavailable, message}}`) when no usable
  implementation is configured — never runs unconfined.
  """
  @spec wrap(spec(), profile()) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  def wrap(spec, profile) do
    case impl() do
      nil -> {:error, {:sandbox_unavailable, refusal_message()}}
      impl -> impl.wrap(spec, profile)
    end
  end
end
