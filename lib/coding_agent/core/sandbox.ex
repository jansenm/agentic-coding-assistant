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

  # A command spec the sandbox knows how to launch.
  #
  #   * {:shell, command}   — run `command` through a shell (`shell` tool).
  #   * {:exec, file, args} — run `file` with `args` directly, no shell
  #     (the `git` tool). This matters: joining a list of agent arguments
  #     into a shell string would make them injectable (`["-m", "x; rm
  #     -rf /"]`), so the sandbox must not introduce a shell around a
  #     list that was never one.
  @type spec :: {:shell, String.t()} | {:exec, String.t(), [String.t()]}

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
  The effective sandbox implementation: the configured module when it is
  usable, otherwise `#{inspect(@none)}`.

  A confining implementation that is not available on this machine (no
  `bwrap`, disabled user namespaces) falls back to the no-op, so a shell
  call never fails at runtime merely because confinement is impossible —
  it runs unconfined, and `confines?/0` is false so the gate keeps asking.
  """
  @spec impl() :: module()
  def impl do
    module = configured()

    (usable?(module) && module) || @none
  end

  defp usable?(module) when is_atom(module) and not is_nil(module) do
    cond do
      # A non-confining implementation (None) has nothing to check.
      not exports?(module, :confines?, 0) -> true
      not module.confines?() -> true
      # A confining implementation must prove it works on this machine.
      exports?(module, :available?, 0) -> module.available?()
      true -> true
    end
  end

  defp usable?(_), do: false

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
  Whether the *effective* implementation confines (ADR 015). This is the
  gate's question: `shell`/`git` may be allow-by-default only when it is
  true.
  """
  @spec confines?() :: boolean()
  def confines? do
    impl = impl()

    exports?(impl, :confines?, 0) and impl.confines?()
  end

  @doc """
  A startup diagnostic for the configured sandbox: `:ok` when it is the
  no-op or the confining implementation works, `{:error, reason}` when a
  confining implementation was requested but cannot run, with a
  human-readable reason. The caller logs it and continues on the fallback.
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
  Wraps `command` as a shell command with the active implementation.
  """
  @spec wrap(spec(), profile()) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  def wrap(spec, profile) do
    impl().wrap(spec, profile)
  end

  @doc "Convenience: wrap a shell command string."
  @spec shell(String.t(), profile()) :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def shell(command, profile) when is_binary(command), do: wrap({:shell, command}, profile)

  @doc "Convenience: wrap a direct executable + argv (no shell)."
  @spec exec(String.t(), [String.t()], profile()) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  def exec(file, args, profile) when is_binary(file) and is_list(args),
    do: wrap({:exec, file, args}, profile)
end
