defmodule CodingAgent.Core.Tools.Git do
  @moduledoc """
  Dedicated git tool (ADR 015 decision 5): run git with `.git` writable.

  Plain `shell` gets `.git` bound read-only, so it can inspect history but
  not commit. This tool's sandbox profile grants `git_write: true`, so the
  agent can `add`, `commit`, `tag`, `reset` and the rest the way it always
  has — without the user having to allow shell `.git` writes wholesale.

  The command is a **git subcommand line**, not a full shell command:
  `args: ["commit", "-m", "msg"]` runs `git commit -m msg`. Everything is
  passed as argv to `git` through the sandbox; there is no shell, so
  quoting/`&&`/subshells in a git command are not a thing here. For a
  script that commits, use `shell` with the `git_write` escalation.

  Gate: allow-by-default when a confining sandbox is active (the tool's
  own profile confines the process), policy-configurable otherwise. Like
  `shell`, it is `:ask` when no sandbox confines the process, and an
  explicit policy entry always wins — so a user who wants every git call
  reviewed writes `[permissions.git] "*" = "ask"`.
  """

  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.Tools

  @default_timeout 120
  @max_timeout 1800

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "git",
      description:
        "Run a git command in the session scope. Pass the git arguments as a " <>
          "list, e.g. [\"commit\", \"-am\", \"fix\"]. Unlike shell, this may " <>
          "write .git (commit/tag/reset). For git inside a script, use shell " <>
          "with git_write.",
      parameter_schema: [
        args: [
          type: {:list, :string},
          required: true,
          doc: "Git arguments, without the leading `git` (e.g. [\"status\"])"
        ],
        timeout_secs: [
          type: :integer,
          required: false,
          doc: "Maximum runtime in seconds (default #{@default_timeout}, max #{@max_timeout})"
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  @doc "Clamps the timeout; the gate and tests share this."
  @spec effective_timeout(term()) :: {:ok, pos_integer()} | {:error, String.t()}
  def effective_timeout(args) when is_map(args) do
    raw = Map.get(args, :timeout_secs) || Map.get(args, "timeout_secs") || @default_timeout

    case coerce(raw) do
      {:ok, secs} when secs > @max_timeout ->
        {:error, "timeout_secs #{secs} exceeds the hard cap of #{@max_timeout}s"}

      {:ok, secs} when secs < 1 ->
        {:ok, 1}

      {:ok, secs} ->
        {:ok, secs}

      :error ->
        {:error, "timeout_secs must be an integer number of seconds"}
    end
  end

  def effective_timeout(_args), do: {:ok, @default_timeout}

  @doc """
  The git argument list for a call, validated (without the leading `git`).
  Returns `{:ok, [sub, ...]}` or `{:error, message}`. Public and pure so
  tests can assert it without running git.
  """
  @spec argv(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def argv(args) when is_map(args) do
    case Map.get(args, :args) || Map.get(args, "args") do
      list when is_list(list) and list != [] ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, "args must be a list of strings"}
        end

      _ ->
        {:error, "args must be a non-empty list of strings, e.g. [\"status\"]"}
    end
  end

  def argv(_args), do: {:error, "args must be a non-empty list of strings"}

  # -- Execution --------------------------------------------------------------

  defp execute(scope, args) do
    argv = Map.get(args, :args) || Map.get(args, "args")

    with {:ok, git_args} <- argv(%{"args" => argv}),
         {:ok, secs} <- effective_timeout(args) do
      run(scope, git_args, secs)
    end
  end

  defp run(scope, git_args, secs) do
    started = System.monotonic_time(:millisecond)
    cwd = Path.expand(scope.root)
    profile = profile(scope)
    command = Enum.join(["git" | git_args], " ")

    case Exec.run({:exec, "git", git_args}, cwd, secs, profile) do
      {:ok, output, status} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, Exec.format(command, output, {:exit, status}, elapsed, secs)}

      {:timeout, partial} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, Exec.format(command, partial, :timeout, elapsed, secs)}

      {:sandbox_error, reason} ->
        Tools.error("cannot confine git: #{inspect(reason)}")

      {:error, reason} ->
        Tools.error("cannot run git: #{:file.format_error(reason)}")
    end
  end

  @doc """
  The sandbox profile for a git call: the scope's mounts plus
  `git_write: true`. Public so the gate and tests share it.
  """
  @spec profile(map()) :: CodingAgent.Core.Sandbox.profile()
  def profile(scope) do
    mounts = Map.get(scope, :mounts) || CodingAgent.Core.Sandbox.Mounts.empty()

    %{
      root: scope.root,
      network: false,
      git_write: true,
      scratch: CodingAgent.Core.Session.Scratch.from_scope(scope),
      rw: Map.get(mounts, :rw, []),
      ro: Map.get(mounts, :ro, []),
      hide: Map.get(mounts, :hide, [])
    }
  end

  defp coerce(secs) when is_integer(secs), do: {:ok, secs}
  defp coerce(secs) when is_float(secs), do: {:ok, trunc(secs)}

  defp coerce(secs) when is_binary(secs) do
    case Integer.parse(secs) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp coerce(_), do: :error
end
