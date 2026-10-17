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

  Gate: since ADR 030 a session only exists under a confining sandbox, so
  the tool is allow-by-default (the profile confines the process); an
  explicit policy entry always wins — a user who wants every git call
  reviewed writes `[permissions.git] "*" = "ask"`.

  Every run carries `Exec.agent_env/0`: an agent `git commit` without
  `-m` (or `rebase --continue`, `tag -a`) must not open the owner's
  editor and hang the turn (review F7).
  """

  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.Escalation
  alias CodingAgent.Core.Tools.Escalation

  @default_timeout 120
  @max_timeout 1800

  @doc """
  The tool's parameter schema. Public so the gate reads the SAME keywords
  the tool declares instead of assuming what a git call may escalate.
  """
  @spec parameter_schema() :: keyword()
  def parameter_schema do
    [
      args: [
        type: {:list, :string},
        required: true,
        doc: "Git arguments, without the leading `git` (e.g. [\"status\"])"
      ],
      timeout_secs: [
        type: :integer,
        required: false,
        doc: "Maximum runtime in seconds (default #{@default_timeout}, max #{@max_timeout})"
      ],
      network: [
        type: :boolean,
        required: false,
        doc:
          "Escalation: allow network access for this call (default false) — required for " <>
            "fetch/clone/push; .git stays writable either way"
      ],
      reason: [
        type: :string,
        required: false,
        doc:
          "REQUIRED when you set network: one short sentence, shown to the human in the " <>
            "approval prompt, explaining why this call needs the escalation."
      ]
    ]
  end

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "git",
      description:
        "Run a git command in the session scope. Pass the git arguments as a " <>
          "list, e.g. [\"commit\", \"-am\", \"fix\"]. Unlike shell, this may " <>
          "write .git (commit/tag/reset). No network unless you request it " <>
          "(network: true + reason) — `fetch` and `clone` need that. For git " <>
          "inside a script, use shell with git_write.",
      parameter_schema: parameter_schema(),
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

  # A `git` call that talks to a remote needs the network, and the gate
  # asks for it from the tool's own schema (see `Gate`). The check runs
  # here rather than being left to `Bwrap`: without it a `fetch` dies on
  # the NAMESPACE with "cannot resolve host", which names neither the cause
  # nor the way out. `ls-remote` is in the list because it is the cheap
  # probe an agent reaches for exactly when it suspects it has no network.
  #
  # Deliberately NOT exhaustive (a script can drive git through a remote
  # helper); this is the message, not the boundary — the grant is the
  # declared escalation and the sandbox enforces it.
  @network_subcommands ~w(fetch clone push pull ls-remote)

  @doc """
  Whether this `git` call needs the network and did not ask for it. Returns
  `nil` when it is fine, a message for the model otherwise.
  """
  @spec network_verdict(term()) :: String.t() | nil
  def network_verdict(args) when is_map(args) do
    if Escalation.granted?(args, :network) do
      nil
    else
      case argv(args) do
        {:ok, [sub | _]} when sub in @network_subcommands ->
          "`git #{sub}` needs the network: retry with `network: true` and a `reason` " <>
            "(the confinement has no network unless a call states it)"

        _ ->
          nil
      end
    end
  end

  def network_verdict(_args), do: nil

  # -- Execution --------------------------------------------------------------

  defp execute(scope, args) do
    case network_verdict(args) do
      nil ->
        with {:ok, git_args} <- argv(args),
             {:ok, secs} <- effective_timeout(args) do
          run(scope, git_args, secs, args)
        end

      message ->
        Tools.error(message)
    end
  end

  defp run(scope, git_args, secs, args) do
    started = System.monotonic_time(:millisecond)
    cwd = Path.expand(scope.root)
    profile = profile(scope, args)
    command = Enum.join(["git" | git_args], " ")

    case Exec.run({:exec, "git", git_args}, cwd, secs, profile,
           env: Exec.agent_env(),
           label: "git"
         ) do
      {:ok, output, status} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, Exec.format(command, output, {:exit, status}, elapsed, secs)}

      {:timeout, partial} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, Exec.format(command, partial, :timeout, elapsed, secs)}

      {:stopped, partial} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, Exec.format(command, partial, :stopped, elapsed, secs)}

      {:sandbox_error, reason} ->
        Tools.error("cannot confine git: #{inspect(reason)}")

      {:error, reason} ->
        Tools.error("cannot run git: #{:file.format_error(reason)}")
    end
  end

  @doc """
  The sandbox profile for a git call: the scope's mounts, `.git` writable
  (ADR 015 decision 4) and the network if — and only if — this call states
  `network: true`.

  The network grant comes from the CALL's `args`, never from the profile
  shape: this function is shared with `Checkpoint.git/4`, whose internal
  git runs must not gain the network because the tool happens to have a
  parameter for it. `args` defaults to `%{}` for exactly that caller, so a
  missing argument can only ever mean "no network".

  Public so the gate and tests share it.
  """
  @spec profile(map(), term()) :: CodingAgent.Core.Sandbox.profile()
  def profile(scope, args \\ %{}) do
    mounts = Map.get(scope, :mounts) || CodingAgent.Core.Sandbox.Mounts.empty()

    %{
      root: scope.root,
      network: Escalation.granted?(args, :network),
      git_write: true,
      session_id: Map.get(scope, :session_id),
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
