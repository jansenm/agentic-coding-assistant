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
      the deliberately-unconfined no-op. ADR 030: a **test seam and an
      explicit opt-out**, never an automatic fallback.
    * `CodingAgent.Core.Sandbox.Bwrap` — bubblewrap on Linux, the shipped
      default.

  Selection mirrors `CodingAgent.Core.Providers.resolve/2`: the
  implementation is data (`:sandbox` application env). When the configured
  implementation is confining but cannot run on this machine, there is
  **no silent fallback to `None`** (ADR 030): `wrap/2` returns
  `{:error, {:sandbox_unavailable, reason}}`, `diagnose/0` reports why,
  and a session refuses to start (`refusal_message/0`). An explicitly
  configured `None` still runs unconfined — that is the deliberate seam.
  """

  @typedoc """
  The access profile for one command. `root` is the session scope root.
  The remaining keys are the coarse grants from ADR 015; an implementation
  that cannot honour a grant must refuse, never silently widen.

    * `:network` — may the process use the network (default false).
    * `:git_write` — may the process write `.git` (default false).
    * `:root_ro` — bind the scope root READ-ONLY (default false). An agent
      with only read tools sets this so `shell` cannot bypass the file-tool
      deny (`echo > f`). A non-confining implementation must REFUSE it,
      never silently run read-write (`None` returns `{:error, :root_ro}`).
    * `:scratch` — a host directory to bind over `/tmp` for the session
      (ADR 022); `nil` keeps the per-call tmpfs, so a scope without a
      session id is unchanged.
    * `:rw` / `:ro` / `:hide` — extra mount directives (user config).
  """
  @type profile :: %{
          required(:root) => String.t(),
          optional(:network) => boolean(),
          optional(:git_write) => boolean(),
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
  # The unconfined stdin wrapper shared by `Sandbox.None` and the test
  # double: a shell pipeline feeding exactly `count` bytes, then closing
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

  @optional_callbacks check: 0

  @doc """
  Whether this implementation actually confines the process. `None` is
  `false`: it is a no-op, so the permission gate must keep asking. Only a
  real sandbox lets `shell`/`git` become allow-by-default (ADR 015).
  """
  @callback confines?() :: boolean()

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
  @none CodingAgent.Core.Sandbox.None

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

  ADR 030 removed the silent fallback to `#{inspect(@none)}`: an
  unavailable confining implementation yields `nil`, so callers must
  refuse rather than run unconfined. An explicitly configured `None` (the
  test seam / deliberate opt-out) is honored and returned as-is.
  """
  @spec impl() :: module() | nil
  def impl do
    module = configured()
    if usable_module?(module), do: module
  end

  defp usable_module?(module) when is_atom(module) and not is_nil(module) do
    cond do
      # A non-confining implementation (None) has nothing to check.
      not exports?(module, :confines?, 0) -> true
      not module.confines?() -> true
      # A confining implementation must prove it works on this machine.
      exports?(module, :available?, 0) -> module.available?()
      true -> true
    end
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
  Whether the *effective* implementation confines (ADR 015/030). An
  unusable configuration confines nothing.
  """
  @spec confines?() :: boolean()
  def confines? do
    case impl() do
      nil -> false
      impl -> exports?(impl, :confines?, 0) and impl.confines?()
    end
  end

  @doc """
  A startup diagnostic for the configured sandbox: `:ok` when it is the
  no-op or the confining implementation works, `{:error, reason}` when a
  confining implementation was requested but cannot run, with a
  human-readable reason.
  """
  @spec diagnose() :: :ok | {:error, String.t()}
  def diagnose do
    module = configured()

    cond do
      not is_atom(module) or is_nil(module) ->
        {:error, "invalid :sandbox configuration: #{inspect(module)}"}

      module == @none ->
        :ok

      not exports?(module, :confines?, 0) or not module.confines?() ->
        :ok

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
      "Install bubblewrap and enable unprivileged user namespaces, or set " <>
      "`sandbox: CodingAgent.Core.Sandbox.None` explicitly to run unconfined."
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
