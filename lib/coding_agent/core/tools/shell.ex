defmodule CodingAgent.Core.Tools.Shell do
  @default_timeout 300
  @min_timeout 1
  @max_timeout 1800

  @moduledoc """
  Shell execution tool (slice 2c). Under ADR 015 the command runs inside a
  sandbox (`CodingAgent.Core.Sandbox`); with a confining sandbox active it
  is allow-by-default *inside the profile*, because its worst-case effect
  is bounded by construction rather than guessed from command text. With
  no confining sandbox (`Sandbox.None`, the default) it falls back to the
  ADR 010 behaviour: every call goes through the permission gate.

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

  Command blacklist (2026-09-15 amendment 2): the gate's real cost was
  *y-fatigue* — most gated calls were grep-style read duplicates of
  native tools. So the direction is a DENY-list, checked before the gate:
  a shell call whose leading program duplicates a native tool denies with
  steering ("please use the grep tool"). Under confinement this is UX
  steering only, never a boundary.

  Output: stdout+stderr combined (merged through /bin/sh), exit code,
  wall time. On truncation head and tail are kept (tail matters for test
  summaries). On timeout the process is killed, and whatever output was
  captured so far is returned together with a timeout note.
  """

  alias CodingAgent.Core.Sandbox
  alias CodingAgent.Core.Tools

  @max_bytes 256 * 1024
  @tail_bytes 128 * 1024

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
      parameter_schema: [
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
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
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
  The requested escalations for a call (ADR 015): `:network` and
  `:git_write`, as coarse booleans the agent states. Returns the list of
  granted escalation names, e.g. `[:network, :git_write]`.
  """
  @spec escalations(term()) :: [atom()]
  def escalations(args) when is_map(args) do
    [:network, :git_write]
    |> Enum.filter(fn key -> truthy?(Map.get(args, key) || Map.get(args, to_string(key))) end)
  end

  def escalations(_args), do: []

  @doc """
  Whether a call requests any escalation. The gate asks for these even
  when confinement would otherwise allow the call.
  """
  @spec escalated?(term()) :: boolean()
  def escalated?(args), do: escalations(args) != []

  @doc """
  Builds the sandbox profile for a call from the scope and the
  escalations the agent requested. Public so the gate and tests share one
  source of truth. `scope` may carry the mount schema (`:mounts`); absent
  or nil mounts add nothing.
  """
  @spec profile(map() | String.t(), term()) :: CodingAgent.Core.Sandbox.profile()
  def profile(scope, args) do
    {root, mounts} =
      case scope do
        %{root: root} = s -> {root, Map.get(s, :mounts) || empty_mounts()}
        root when is_binary(root) -> {root, empty_mounts()}
      end

    %{
      root: root,
      network: truthy?(Map.get(args, :network) || Map.get(args, "network")),
      git_write: truthy?(Map.get(args, :git_write) || Map.get(args, "git_write")),
      rw: Map.get(mounts, :rw, []),
      ro: Map.get(mounts, :ro, []),
      hide: Map.get(mounts, :hide, [])
    }
  end

  defp empty_mounts, do: %{rw: [], ro: [], hide: []}

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

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

  # -- Command blacklist (2026-09-15 ADR 010 amendment 2) ----------------------
  #
  # The OPPOSITE of an allow-list: not "these commands are safe", but
  # "this shell spelling duplicates a native tool — use the tool". The
  # gate (Session.gate_tools) consults this BEFORE the policy lookup,
  # so a denied call never costs a keystroke and the redirect message
  # steers the model in the same round. Enforcement stays at the gate;
  # the tool callback remains a pure executor (a direct ReqLLM.Tool
  # execution bypasses this check — the gate is the policy point).

  @redirect %{
    "grep" =>
      "please use the grep tool instead of shell grep (it is allow-by-policy and returns capped, line-numbered matches)",
    "rg" => "please use the grep tool instead of shell rg",
    "ag" => "please use the grep tool instead of shell ag",
    "ack" => "please use the grep tool instead of shell ack",
    # sg = sushi-ripgrep's wrapper; the name collision with the Unix
    # set-group sg is accepted — an agent essentially never wants that
    "sg" => "please use the grep tool instead of shell sg",
    "timeout" => "please set the timeout as a parameter on the tool call"
  }

  @doc """
  The command-blacklist verdict for a shell call's arguments: `{:ok, guidance}` when the leading
  program duplicates a native tool (the value is the denied message for the model), `:error`
  otherwise.

  Deliberately shallow, on purpose: the FIRST program word only — basename of an absolute path,
  after env-var assignments (`FOO=1`). Pipes do not widen the check (`echo hi | grep hi` runs) and
  neither do evader spellings (`git grep`, `awk`, `find -exec`). This is prompt hygiene, not
  containment — shell stays ask-at-the-gate for everything not listed.
  """
  @spec blacklisted?(term()) :: {:ok, String.t()} | :error
  def blacklisted?(args) when is_map(args) do
    command = Map.get(args, :command) || Map.get(args, "command")

    with {:ok, prog} <- leading_program(command),
         {:ok, guidance} <- Map.fetch(@redirect, prog) do
      {:ok, guidance}
    end
  end

  def blacklisted?(_args), do: :error

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

    case exec(scope, command, cwd, secs, args) do
      {:ok, output, status} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, format(command, output, {:exit, status}, elapsed, secs)}

      {:timeout, partial} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, format(command, partial, :timeout, elapsed, secs)}

      {:error, reason} ->
        Tools.error("cannot run #{inspect(command)}: #{:file.format_error(reason)}")

      {:sandbox_error, reason} ->
        Tools.error("cannot confine #{inspect(command)}: #{inspect(reason)}")
    end
  end

  # Port loop: /bin/sh merges stderr into stdout; `exit_status` delivers
  # the code, then the port sends :closed. A command usually ends up as
  # the sh process itself (sh -c execs its last command), so killing the
  # port's os_pid kills the command; process groups are deliberately out
  # of scope for v1 (documented in about-tools).
  #
  # The executable and argv come from `CodingAgent.Core.Sandbox` (ADR
  # 015): with the default `Sandbox.None` this is `/bin/sh -c <command>`
  # exactly as before; with `Sandbox.Bwrap` it is bwrap wrapping the
  # command. `{:cd, cwd}` still applies to whatever process we spawn;
  # a sandbox that needs the scope root takes it from the profile.
  defp exec(scope, command, cwd, secs, args) do
    profile = profile(scope, args)

    case Sandbox.wrap(command, profile) do
      {:ok, executable, argv} ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            {:args, argv},
            {:cd, cwd}
          ])

        deadline = System.monotonic_time(:millisecond) + secs * 1000
        collect(port, deadline, "")

      {:error, reason} ->
        {:sandbox_error, reason}
    end
  end

  # Ports deliver :exit_status then :closed. We never Port.close/1 by
  # hand on a live port: once the os process ends, the port closes
  # itself, and closing an already-closed port raises :badarg.
  defp collect(port, deadline, buf) do
    receive do
      {^port, {:data, data}} ->
        collect(port, deadline, [buf | data])

      {^port, {:exit_status, code}} ->
        wait_closed(port)
        {:ok, truncate(buf), code}

      {^port, :closed} ->
        # os process died without a status delivery (e.g. killed by us
        # earlier or exec failure) — treat as failure signal
        {:ok, truncate(buf), 1}
    after
      remaining = remaining(deadline) ->
        if remaining <= 0 do
          kill(port)
          {:timeout, truncate(buf)}
        else
          collect(port, deadline, buf)
        end
    end
  end

  # After :exit_status the port sends :closed on its own; give it a
  # moment so the next collect iteration doesn't see a dead port, but
  # never block indefinitely.
  defp wait_closed(port) do
    receive do
      {^port, :closed} ->
        :ok

      {^port, {:data, _data}} ->
        wait_closed(port)
    after
      50 ->
        :ok
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp kill(port) do
    case Port.info(port) do
      nil ->
        :ok

      info ->
        os_pid = Keyword.get(info, :os_pid)

        if os_pid do
          System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
        end

        receive do
          {^port, {:exit_status, _code}} ->
            wait_closed(port)

          {^port, :closed} ->
            :ok
        after
          250 ->
            :ok
        end
    end
  end

  defp truncate(chunks) do
    data = IO.iodata_to_binary(chunks)
    size = byte_size(data)

    if size <= @max_bytes do
      data
    else
      head = binary_part(data, 0, @max_bytes - @tail_bytes)
      tail = binary_part(data, size - @tail_bytes, @tail_bytes)

      head <>
        "\n\n[... output truncated: #{size} bytes total; showing first " <>
        "#{byte_size(head)} and last #{@tail_bytes} ...]\n\n" <> tail
    end
  end

  defp format(command, output, status, elapsed_ms, secs_requested) do
    status_line =
      case status do
        {:exit, 0} -> "exit 0"
        {:exit, code} -> "exit #{code} (non-zero — the command failed)"
        :timeout -> "TIMED OUT after #{secs_requested}s (output below is partial)"
      end

    """
    $ #{command}
    #{status_line}, took #{div(elapsed_ms, 1000)}s
    --- output ---
    #{if output == "", do: "(no output)", else: output}\
    """
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
