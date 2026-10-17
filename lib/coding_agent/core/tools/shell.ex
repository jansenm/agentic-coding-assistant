defmodule CodingAgent.Core.Tools.Shell do
  @default_timeout 300
  @min_timeout 1
  @max_timeout 1800

  @moduledoc """
  Shell execution tool (slice 2c). Under ADR 015 the command runs inside a
  sandbox (`CodingAgent.Core.Sandbox`); a confining sandbox is always
  active (ADR 030), so it is allow-by-default *inside the profile*,
  because its worst-case effect is bounded by construction rather than
  guessed from command text.

  Two coarse **escalations** re-enable the prompt even under confinement,
  and the agent must *state* them — they are never inferred from the
  command text (ADR 015):

    * `network: true` — may this call use the network (default false);
    * `git_write: true` — may this call write `.git` (default false; for
      scripts that commit, e.g. a release script).

  The gate surfaces the requested timeout at the soft cap
  (#{@default_timeout}s) so the user can edit it before approval; the
  hard cap (#{@max_timeout}s) refuses longer runs and tells the model to
  split the work.

  Command redirects (2026-09-15 amendment 2): the gate's real cost was
  *y-fatigue* — most gated calls were grep-style read duplicates of
  native tools. So the gate consults a table of *redirects* before the
  policy: a shell call whose leading program duplicates a native tool is
  answered with a one-line hint ("please use the grep tool") instead of
  a keystroke. Under confinement this is UX steering only, never a
  boundary — the mount bounds the call, not the command text.

  Output: stdout+stderr combined (merged through /bin/sh), exit code,
  wall time. On truncation head and tail are kept (tail matters for test
  summaries). On timeout the process is killed, and whatever output was
  captured so far is returned together with a timeout note.
  """

  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.Escalation

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "shell",
      description:
        "Run a shell command in the session scope root (through /bin/sh). " <>
          "Captures stdout and stderr, and reports the exit code. Give long " <>
          "commands a suitable timeout_secs (seconds); the hard cap is " <>
          "#{@max_timeout}s — split longer work into several commands. " <>
          "The command runs confined (filesystem limited to the scope and " <>
          "configured caches, no network); it cannot write .git unless you " <>
          "request git_write. These escalations require approval.",
      parameter_schema: parameter_schema(),
      callback: fn args -> execute(scope, args) end
    )
  end

  @doc """
  The tool's parameter schema. Public so the gate reads the SAME keywords
  the tool declares instead of assuming what a shell call may escalate.
  """
  @spec parameter_schema() :: keyword()
  def parameter_schema do
    [
      command: [type: :string, required: true, doc: "The shell command to run"],
      timeout_secs: [
        type: :integer,
        required: false,
        doc: "Maximum runtime in seconds (default #{@default_timeout}, max #{@max_timeout})"
      ],
      network: [
        type: :boolean,
        required: false,
        doc: "Escalation: allow network access for this call (default false)"
      ],
      git_write: [
        type: :boolean,
        required: false,
        doc: "Escalation: allow writing .git for this call (default false)"
      ],
      reason: [
        type: :string,
        required: false,
        doc:
          "REQUIRED when you set network or git_write: one short sentence, " <>
            "shown to the human in the approval prompt, explaining why this " <>
            "call needs the escalation. A request without a reason is refused."
      ]
    ]
  end

  @doc """
  The timeout is actually used for an execution, after clamping.
  Used by the gate (soft-cap decision) and tests.
  """
  @spec effective_timeout(term()) :: {:ok, pos_integer()} | {:error, String.t()}
  def effective_timeout(args) when is_map(args) do
    raw = Map.get(args, :timeout_secs) || Map.get(args, "timeout_secs") || @default_timeout

    case coerce(raw) do
      {:ok, secs} when secs > @max_timeout ->
        {:error,
         "timeout_secs #{secs} exceeds the hard cap of #{@max_timeout}s; " <>
           "split the work into several commands"}

      {:ok, secs} when secs < @min_timeout ->
        {:ok, @min_timeout}

      {:ok, secs} ->
        {:ok, secs}

      :error ->
        {:error, "timeout_secs must be an integer number of seconds"}
    end
  end

  def effective_timeout(_args), do: {:ok, @default_timeout}

  @doc "The soft cap: requested timeouts above this are flagged at the gate."
  def soft_cap, do: @default_timeout

  @doc """
  The escalations a `shell` call states (ADR 015): `:network` and
  `:git_write`, as coarse booleans the agent says. See
  `CodingAgent.Core.Tools.Escalation`, which owns the semantics; `shell`
  declares both keywords, so every escalation applies to it.
  """
  @spec escalations(term()) :: [Escalation.name()]
  def escalations(args), do: Escalation.requested(args)

  @doc "Whether a `shell` call asks to widen its profile at all."
  @spec escalated?(term()) :: boolean()
  def escalated?(args), do: escalations(args) != []

  @doc "The agent's stated reason for an escalation, or `nil`."
  @spec reason(term()) :: String.t() | nil
  defdelegate reason(args), to: Escalation

  @doc "The escalation gate verdict: `:ok`, or `{:error, guidance}` when a stated escalation has no reason."
  @spec escalation_verdict(term()) :: :ok | {:error, String.t()}
  defdelegate escalation_verdict(args), to: Escalation, as: :verdict

  @doc """
  Builds the sandbox profile for a call from the scope and the
  escalations the agent requested. Public so the gate and tests share one
  source of truth. `scope` may carry the mount schema (`:mounts`); absent
  or nil mounts add nothing.
  """
  @spec profile(map() | String.t(), term()) :: CodingAgent.Core.Sandbox.profile()
  def profile(scope, args) do
    {root, mounts, shell_mode} =
      case scope do
        %{root: root} = s ->
          {root, Map.get(s, :mounts) || CodingAgent.Core.Sandbox.Mounts.empty(),
           Map.get(s, :shell_mode, :rw)}

        root when is_binary(root) ->
          {root, CodingAgent.Core.Sandbox.Mounts.empty(), :rw}
      end

    %{
      root: root,
      network: Escalation.granted?(args, :network),
      git_write: Escalation.granted?(args, :git_write),
      # a read-only agent's shell cannot write the source either; an
      # unconfined sandbox refuses this rather than running read-write
      root_ro: shell_mode == :ro,
      session_id: session_id(scope),
      scratch: scratch(scope),
      rw: Map.get(mounts, :rw, []),
      ro: Map.get(mounts, :ro, []),
      hide: Map.get(mounts, :hide, [])
    }
  end

  defp session_id(%{} = scope), do: Map.get(scope, :session_id)
  defp session_id(_root), do: nil

  # The session scratch (ADR 022): nil for a bare root scope, so the
  # sandbox keeps its ephemeral tmpfs `/tmp`.
  defp scratch(%{} = scope), do: CodingAgent.Core.Session.Scratch.from_scope(scope)
  defp scratch(_root), do: nil

  # -- Execution --------------------------------------------------------------

  defp execute(scope, args) do
    command = Map.get(args, :command) || Map.get(args, "command")

    cond do
      not is_binary(command) or command == "" ->
        Tools.error("command must be a non-empty string")

      true ->
        with {:ok, secs} <- effective_timeout(args) do
          run(scope, command, Path.expand(scope.root), secs, args)
        end
    end
  end

  # -- Command redirects (2026-09-15 ADR 010 amendment 2) ----------------------
  #
  # Not "these commands are safe", but "this shell spelling duplicates a
  # native tool — use the tool". The gate (Session.Gate) consults this
  # BEFORE the policy lookup, so a redirected call never costs a
  # keystroke and the hint reaches the model in the same round.
  # Enforcement stays at the gate; the tool callback remains a pure
  # executor (a direct ReqLLM.Tool execution bypasses this check — the
  # gate is the policy point).
  #
  # The table is ADVICE, never a wall (owner ruling 2026-10-13). Which
  # spellings it can see is a coincidence of the first word: `git add`
  # matches a row, `bash -c 'git add …'` does not. So a hint may not be
  # the last word — it would steer the honest spelling away while the
  # wrapped one reached the gate and ran. The escape is the one the
  # caller already has: STATE an escalation (`git_write: true`/`network:
  # true` plus a `reason`), and the call goes to the human instead of
  # getting advice. See `redirect/1`.

  @redirect %{
    "grep" =>
      "please use the grep tool instead of shell grep (it is allow-by-policy and returns capped, line-numbered matches)",
    "rg" => "please use the grep tool instead of shell rg",
    "ag" => "please use the grep tool instead of shell ag",
    "ack" => "please use the grep tool instead of shell ack",
    # sg = sushi-ripgrep's wrapper; the name collision with the Unix
    # set-group sg is accepted — an agent essentially never wants that
    "sg" => "please use the grep tool instead of shell sg",
    "git" =>
      "please use your git tool instead of shell git (it is allow-by-default, runs git directly and may write .git) — git inside a script that CHANGES the repository needs the parameter git_write: true plus a reason on the shell call",
    "timeout" => "please set the timeout as a parameter on the tool call"
  }

  @doc """
  The redirect verdict for a shell call's arguments: `{:hint, guidance}` when the leading
  program duplicates a native tool (the value is the hint for the model), `:ok` otherwise.

  `:ok` is not "this command is safe" — nothing here decides that; the sandbox profile does.
  It means only "nothing to redirect you to". The first return is a hint, not a result, which
  is why it is tagged instead of being a bare `{:ok, message}` next to `:error`.

  **The hint is advice, never a wall.** A call that *states* an escalation (`network: true` /
  `git_write: true`, each with its `reason`) is asking to run this command as written by hand,
  and goes to the gate like any other escalated call — no hint. Without that, the table's
  first-word blindness would invert the outcome: the honest `git add` (escalation stated) would
  be steered away, while `bash -c 'git add …'` reached the human and ran.

  Deliberately shallow, on purpose: the FIRST program word only — basename of an absolute path,
  after env-var assignments (`FOO=1`). Pipes do not widen the check (`echo hi | grep hi` runs) and
  neither do evader spellings (`git grep`, `awk`, `find -exec`). This is prompt hygiene, not
  containment — shell stays ask-at-the-gate for everything not listed.
  """
  @spec redirect(term()) :: :ok | {:hint, String.t()}
  def redirect(args) when is_map(args) do
    if escalated?(args), do: :ok, else: hint_for(args)
  end

  def redirect(_args), do: :ok

  defp hint_for(args) do
    command = Map.get(args, :command) || Map.get(args, "command")

    with {:ok, prog} <- leading_program(command),
         {:ok, hint} <- Map.fetch(@redirect, prog) do
      {:hint, hint}
    else
      _ -> :ok
    end
  end

  defp leading_program(command) when is_binary(command) do
    command
    |> String.trim_leading()
    |> String.split(~r/\s+/)
    |> Enum.drop_while(fn token ->
      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, token)
    end)
    |> case do
      [] -> :error
      [prog | _rest] -> {:ok, Path.basename(prog)}
    end
  end

  defp leading_program(_), do: :error

  defp run(scope, command, cwd, secs, args) do
    started = System.monotonic_time(:millisecond)
    profile = profile(scope, args)

    case Exec.run({:shell, command}, cwd, secs, profile, env: Exec.agent_env(), label: "shell") do
      {:ok, output, status} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, Exec.format(command, output, {:exit, status}, elapsed, secs)}

      {:timeout, partial} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, Exec.format(command, partial, :timeout, elapsed, secs)}

      {:stopped, partial} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, Exec.format(command, partial, :stopped, elapsed, secs)}

      {:error, reason} ->
        Tools.error("cannot run #{inspect(command)}: #{:file.format_error(reason)}")

      {:sandbox_error, reason} ->
        Tools.error("cannot confine #{inspect(command)}: #{inspect(reason)}")
    end
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
