defmodule CodingAgent.Core.Tools.Shell do
  @default_timeout 300
  @min_timeout 1
  @max_timeout 1800

  @moduledoc """
  Shell execution tool (slice 2c), per ADR 010: always-ask in v1.

  No path containment on purpose — a shell trivially bypasses file-tool
  checks, which is exactly why every call goes through the permission
  gate. The gate surfaces the requested timeout at the soft cap
  (#{@default_timeout}s) so the user can edit it before approval; the
  hard cap (#{@max_timeout}s) refuses longer runs and tells the model
  to split the work.

  Command blacklist (2026-09-15 amendment 2, same day as the
  allow-class amendment): the gate's real cost in live sessions was not
  danger but *y-fatigue* — most gated calls were grep-style read
  duplicates of native tools. So the direction is a DENY-list, checked
  before the gate: a shell call whose leading program duplicates a
  native tool denies with steering ("please use the grep tool") — the
  native grep is allow-by-policy, so this saves the user a keystroke
  AND tells the model the better tool in the same round. v1 covers the
  grep family (grep/sg/rg/ag/ack); sed → edit/read_file, cat →
  read_file, ls → list_dir are one-line follow-ups.

  The check is deliberately shallow (first command word after
  shelling-out wrappers like `env`/`command`/`exec`; basename of an
  absolute path) and honest about scope: guidance at the gate, not
  containment — `git grep`, `awk`, `find -exec`, `bash -c` pass, and a
  malicious agent is not stoppable by a word list (the human still sees
  the full command on every non-denied call).

  Output: stdout+stderr combined (merged through /bin/sh), exit code,
  wall time. On truncation head and tail are kept (tail matters for
  test summaries). On timeout the process is killed and whatever output
  was captured so far is returned together with a timeout note.
  """

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
          "Subject to the permission policy; requires approval.",
      parameter_schema: [
        command: [type: :string, required: true, doc: "The shell command to run"],
        timeout_secs: [
          type: :integer,
          required: false,
          doc: "Maximum runtime in seconds (default #{@default_timeout}, max #{@max_timeout})"
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  @doc """
  The timeout actually used for an execution, after clamping.
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

  # -- Execution --------------------------------------------------------------

  defp execute(scope, args) do
    command = Map.get(args, :command) || Map.get(args, "command")

    cond do
      not is_binary(command) or command == "" ->
        Tools.error("command must be a non-empty string")

      true ->
        with {:ok, secs} <- effective_timeout(args) do
          run(command, Path.expand(scope.root), secs)
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
    "sg" => "please use the grep tool instead of shell sg"
  }

  @wrappers ["env", "command", "nohup"]

  @doc """
  The command-blacklist verdict for a shell call's arguments:
  `{:ok, guidance}` when the leading program duplicates a native tool
  (the value is the deny message for the model), `:error` otherwise.

  Deliberately shallow, on purpose: the FIRST program word only —
  basename of an absolute path, after env-var assignments (`FOO=1`)
  and shelling-out wrappers (`env`, `command`, `nohup`). Pipes do not
  widen the check (`echo hi | grep hi` runs) and neither do evader
  spellings (`git grep`, `awk`, `find -exec`). This is prompt
  hygiene, not containment — shell stays ask-at-the-gate for
  everything not listed.
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
      token in @wrappers or Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, token)
    end)
    |> case do
      [] -> :error
      [prog | _rest] -> {:ok, Path.basename(prog)}
    end
  end

  defp leading_program(_), do: :error

  defp run(command, cwd, secs) do
    started = System.monotonic_time(:millisecond)

    case exec(command, cwd, secs) do
      {:ok, output, status} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, format(command, output, {:exit, status}, elapsed, secs)}

      {:timeout, partial} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, format(command, partial, :timeout, elapsed, secs)}

      {:error, reason} ->
        Tools.error("cannot run #{inspect(command)}: #{:file.format_error(reason)}")
    end
  end

  # Port loop: /bin/sh merges stderr into stdout; `exit_status` delivers
  # the code, then the port sends :closed. A command usually ends up as
  # the sh process itself (sh -c execs its last command), so killing the
  # port's os_pid kills the command; process groups are deliberately out
  # of scope for v1 (documented in about-tools).
  defp exec(command, cwd, secs) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, ["-c", command]},
        {:cd, cwd}
      ])

    deadline = System.monotonic_time(:millisecond) + secs * 1000
    collect(port, deadline, "")
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
