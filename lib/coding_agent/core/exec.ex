defmodule CodingAgent.Core.Exec do
  @moduledoc """
  The one process executor: spawn a command through the active sandbox,
  collect stdout+stderr with a deadline, return the exit status.

  Shared by `Tools.Shell` and `Tools.Git` so the port discipline (kill on
  timeout, truncation, output format) exists once. The sandbox call
  (`CodingAgent.Core.Sandbox.wrap/2`) happens here, at the single
  `Port.open/2` site — per ADR 015 the *process* is bounded, not the
  command text.
  """

  alias CodingAgent.Core.Sandbox

  @max_bytes 256 * 1024
  @tail_bytes 128 * 1024

  @typedoc "Execution outcome before formatting."
  @type outcome ::
          {:ok, String.t(), non_neg_integer()}
          | {:timeout, String.t()}
          | {:error, term()}
          | {:sandbox_error, term()}

  @doc """
  Runs a command spec in `cwd` under `profile`, killing it after `secs`.
  """
  @spec run(Sandbox.spec(), String.t(), pos_integer(), Sandbox.profile()) :: outcome()
  def run(spec, cwd, secs, profile) do
    case Sandbox.wrap(spec, profile) do
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
      remaining(deadline) ->
        on_deadline(port, deadline, buf)
    end
  end

  # The receive `after` clause takes a literal timeout expression in
  # modern Elixir; assigning inside it trips cover's instrumenter, so the
  # decision lives here. `remaining(deadline)` above already blocked for
  # the time left; recompute — it is cheap and always <= 0 on this path.
  defp on_deadline(port, deadline, buf) do
    if remaining(deadline) <= 0 do
      kill(port)
      {:timeout, truncate(buf)}
    else
      collect(port, deadline, buf)
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

  @doc "Truncates output, keeping head and tail (tail matters for test summaries)."
  @spec truncate(iodata()) :: String.t()
  def truncate(chunks) do
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

  @doc """
  Formats a tool result for the model: the command, a status line, and
  the combined output.
  """
  @spec format(
          String.t(),
          String.t(),
          {:exit, integer()} | :timeout,
          non_neg_integer(),
          pos_integer()
        ) ::
          String.t()
  def format(command, output, status, elapsed_ms, secs_requested) do
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
end
