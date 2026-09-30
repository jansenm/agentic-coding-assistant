defmodule CodingAgent.Core.Exec do
  @moduledoc """
  The one process executor: spawn a command through the active sandbox,
  collect stdout+stderr with a deadline, return the exit status.

  Shared by `Tools.Shell` and `Tools.Git` so the port discipline (kill on
  timeout, truncation, output format) exists once. The sandbox call
  (`CodingAgent.Core.Sandbox.wrap/2`) happens here, at the single
  `Port.open/2` site — per ADR 015 the *process* is bounded, not the
  command text.

  ## Cancellation (esc)

  A running command is killed when the owning session asks it to stop
  (`Interrupt.requested?/1`), not only at its own deadline. The profile
  carries the session id (ADR 022's `:scratch` is derived from it, so the
  tools already place it there); while `collect/4` waits it wakes every
  `@poll_ms` to check the flag. This is what lets a double-esc end a
  command that would otherwise run to a `shell` timeout of up to 1800s —
  the cooperative flag was only read *between* tool calls before. A
  command with no session id (a bare test, `checkpoint`'s internal
  bookkeeping) simply keeps its deadline.
  """

  alias CodingAgent.Core.Interrupt
  alias CodingAgent.Core.Sandbox
  alias CodingAgent.Core.Spill

  @max_bytes 256 * 1024
  @tail_bytes 128 * 1024
  # the head we keep for the display; the rolling tail follows it
  @head_bytes @max_bytes - @tail_bytes

  # A `truncate: false` caller (`grep`, `glob`) wants the whole stream and
  # cannot use the head/tail cut, so its buffer is bounded only by this
  # hard safety cap: past it the command is killed and the caller gets
  # `{:raw_too_large, _}` rather than the BEAM growing to OOM. Generous —
  # far above any real search — and only reachable by a runaway producer.
  @max_raw_bytes 64 * 1024 * 1024

  # While a command runs, `collect/4` wakes at most this often to look for
  # a user stop (see the moduledoc's "cancellation" note). A quiet hang
  # (`sleep 3000`) sends no message, so without this tick the receive would
  # stay parked to the deadline and esc could not reach it.
  @poll_ms 250

  @doc """
  Environment overrides every agent-initiated command runs with (review
  F7): the human is not at the terminal the process runs on, so an
  interactive program must never wait for one. Git is the concrete
  case — the owner's `EDITOR`/`VISUAL` leaked into agent `git commit`
  (no `-m`), `rebase --continue`, `tag -a`, which opened gvim and hung
  the turn. `GIT_EDITOR=true` accepts the default message, the sequence
  editor is neutralized, prompts are disabled and pagers are bypassed
  (output is captured anyway).

  Shared by the `git` and `shell` tools so the rule exists once.
  """
  @spec agent_env() :: [{String.t(), String.t()}]
  def agent_env do
    [
      {"GIT_EDITOR", "true"},
      {"GIT_SEQUENCE_EDITOR", "true"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_PAGER", "cat"},
      {"PAGER", "cat"}
    ]
  end

  @typedoc "Execution outcome before formatting."
  @type outcome ::
          {:ok, String.t(), non_neg_integer()}
          | {:timeout, String.t()}
          | {:stopped, String.t()}
          | {:error, term()}
          | {:sandbox_error, term()}

  @doc """
  Runs a command spec in `cwd` under `profile`, killing it after `secs`.

  `opts`:

    * `:stdin` — iodata written to the process's standard input. A port
      cannot signal EOF, so `run/5` wraps the spec as
      `{:stdin, byte_size, spec}`: the sandbox pipes exactly those bytes
      from `head -c N` and the pipe close is the child's EOF (ADR 030,
      `write_file` as a confined `tee`).
    * `:env` — environment overrides (`{name, value}` string pairs),
      merged over the inherited environment. Used to neutralize
      interactive tools (`GIT_EDITOR=true`; ADR 030 / review F7).
    * `:truncate` — whether to cut output past `@max_bytes`, keeping head
      and tail (default `true`). A MACHINE consumer (the `fd` filename
      enumerator) passes `false`: the truncation banner is prose, not a
      path, and parsing it produced a phantom match (review F2/F5).
    * `:label` — the spill label (ADR 038) used when truncation happens:
      the overflow is written to the session scratch (the profile's
      `:scratch`, ADR 022) and the head+tail marker names the path so the
      model can read the rest. Defaults to `"exec"`. With no scratch the
      plain head+tail truncation stands. `nil` suppresses the spill
      entirely (a reader that only needs "is it too big?", not the text).
    * `:max_output` — the hard byte ceiling for the `truncate: false`
      (raw) mode; default `@max_raw_bytes`. A caller with its own cap
      (`read_file`) passes `cap + 1` so the command is stopped the moment
      the cap is exceeded, instead of being served a silently truncated
      result (`{:raw_too_large, _}` instead of data loss).
  """
  @spec run(Sandbox.spec(), String.t(), pos_integer(), Sandbox.profile(), keyword()) :: outcome()
  def run(spec, cwd, secs, profile, opts \\ []) do
    stdin = Keyword.get(opts, :stdin)
    env = Keyword.get(opts, :env, [])
    truncate? = Keyword.get(opts, :truncate, true)
    label = Keyword.get(opts, :label, "exec")
    max_output = Keyword.get(opts, :max_output, @max_raw_bytes)
    scratch = Map.get(profile, :scratch)
    session_id = Map.get(profile, :session_id)

    spec =
      case stdin do
        nil -> spec
        data -> {:stdin, IO.iodata_length(data), spec}
      end

    case Sandbox.wrap(spec, profile) do
      {:ok, executable, argv} ->
        port = open(executable, argv, cwd, env)

        deliver_stdin(port, stdin)

        deadline = System.monotonic_time(:millisecond) + secs * 1000
        cut = %{truncate?: truncate?, label: label, scratch: scratch, max_raw: max_output}

        collect(port, deadline, new_acc(cut), cut, session_id)

      {:error, reason} ->
        {:sandbox_error, reason}
    end
  end

  defp open(executable, argv, cwd, env) do
    options = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :hide,
      {:args, argv},
      {:cd, cwd}
    ]

    options =
      if env == [] do
        options
      else
        options ++ [{:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}]
      end

    Port.open({:spawn_executable, executable}, options)
  end

  # The payload for `{:stdin, count, _}`. `Port.command/2` is
  # synchronous, so the bytes are in the port's buffer before `collect/3`
  # starts reading; the child sees them as its standard input.
  defp deliver_stdin(_port, nil), do: :ok

  defp deliver_stdin(port, data) do
    Port.command(port, data)
    :ok
  end

  # Ports deliver :exit_status then :closed. We never Port.close/1 by
  # hand on a live port: once the os process ends, the port closes
  # itself, and closing an already-closed port raises :badarg.
  #
  # The `after` is the MINIMUM of the time left to the deadline and
  # `@poll_ms`: a running command's data messages wake the receive first,
  # but a silent one is re-checked for a user stop on this tick.
  #
  # ## Bounded memory (the OOM freeze, 2026-09-30)
  #
  # Every chunk is folded through `ingest/2`, which caps what is held in
  # the BEAM. Before this, `buf` grew without limit: a `while true; do
  # echo; done` (any fast printer) reached 11 GB and four OOM kills that
  # froze the whole desktop, because truncation only ran at process exit.
  # Now, once `@max_bytes` is passed, the accumulator STREAMS: the head is
  # frozen, the tail is a rolling window, and further chunks are appended
  # to the session scratch (ADR 038's `Spill`). Memory is O(`@max_bytes`),
  # not O(output).
  defp collect(port, deadline, acc, cut, session_id) do
    receive do
      {^port, {:data, data}} ->
        case ingest(acc, data) do
          {:ok, acc} ->
            collect(port, deadline, acc, cut, session_id)

          :overflow ->
            # a machine consumer (`grep`/`fd`, `truncate: false`) keeps the
            # whole output by contract; past the hard safety cap we refuse
            # rather than reproduce the OOM — a bounded, honest failure.
            kill(port)
            {:raw_too_large, finish(acc, cut)}
        end

      {^port, {:exit_status, code}} ->
        wait_closed(port)
        {:ok, finish(acc, cut), code}

      {^port, :closed} ->
        # os process died without a status delivery (e.g. killed by us
        # earlier or exec failure) — treat as failure signal
        {:ok, finish(acc, cut), 1}
    after
      wake_timeout(deadline, session_id) ->
        on_wake(port, deadline, acc, cut, session_id)
    end
  end

  # Two accumulator shapes. `:raw` keeps everything (bounded by
  # `@max_raw_bytes`). `:buffer` holds up to `@max_bytes`; crossing that
  # freezes `:head` and `:tail` and flips to streaming into `:spill`.
  # `cut` (label + scratch) rides along so the lazy spill can open.
  defp new_acc(cut) do
    if cut.truncate? do
      %{mode: :buffer, buf: [], total: 0, head: nil, tail: <<>>, spill: :unopened, cut: cut}
    else
      %{mode: :raw, chunks: [], size: 0, cut: cut}
    end
  end

  defp ingest(%{mode: :raw, chunks: chunks, size: n, cut: cut} = acc, data) do
    n = n + IO.iodata_length(data)
    if n > cut.max_raw, do: :overflow, else: {:ok, %{acc | chunks: [chunks | data], size: n}}
  end

  defp ingest(%{mode: :buffer, buf: buf, total: total, cut: cut} = acc, data) do
    total = total + IO.iodata_length(data)

    if total <= @max_bytes do
      {:ok, %{acc | buf: [buf | data], total: total}}
    else
      # crossing the cap: materialize once, split head/tail, spill the
      # WHOLE buffer, and stream from here on.
      all = IO.iodata_to_binary([buf | data])
      head = binary_part(all, 0, @head_bytes)
      tail = binary_part(all, byte_size(all) - @tail_bytes, @tail_bytes)
      spill = cut.scratch |> open_spill(cut.label) |> spill_write(all)

      {:ok, %{acc | mode: :stream, buf: nil, total: total, head: head, tail: tail, spill: spill}}
    end
  end

  defp ingest(%{mode: :stream, head: head, tail: tail, total: total, spill: spill} = acc, data) do
    spill = spill_write(spill, data)

    {:ok,
     %{
       acc
       | head: head,
         tail: roll_tail(tail, data),
         total: total + IO.iodata_length(data),
         spill: spill
     }}
  end

  defp roll_tail(tail, data) do
    combined = tail <> data

    if byte_size(combined) > @tail_bytes do
      binary_part(combined, byte_size(combined) - @tail_bytes, @tail_bytes)
    else
      combined
    end
  end

  # the spill opens lazily on first overflow; no scratch or no label
  # (a reader that only wants the cap check) => :none
  defp open_spill(_scratch, label) when not is_binary(label), do: :none

  defp open_spill(scratch, label) do
    case Spill.open_writer(scratch, label) do
      {:ok, w} -> w
      _ -> :none
    end
  end

  defp spill_write(spill, _data) when spill in [:none, :unopened], do: spill

  defp spill_write(spill, data) when is_map(spill) do
    case Spill.write(spill, data) do
      {:ok, w} -> w
      {:capped, w} -> w
    end
  end

  defp finish(%{mode: :raw, chunks: chunks}, _cut), do: IO.iodata_to_binary(chunks)

  defp finish(%{mode: :buffer, buf: buf}, _cut), do: IO.iodata_to_binary(buf)

  defp finish(%{mode: :stream, head: head, tail: tail, total: total, spill: spill}, _cut) do
    path = close_spill(spill)

    head <>
      "\n\n[... output truncated: #{total} bytes total; showing first " <>
      "#{byte_size(head)} and last #{@tail_bytes}#{path_note(path)} ...]\n\n" <> tail
  end

  # Closes the spill (idempotent) and returns the sandbox path to name.
  defp close_spill(spill) when is_map(spill) do
    {:ok, closed} = Spill.finish(spill)
    closed.path
  end

  defp close_spill(_), do: nil

  defp path_note(nil), do: ""
  defp path_note(path), do: "; full output at #{path}"

  # Wake at the poll interval, or at the deadline if that is sooner. With
  # no session to watch there is nothing to check, so wait the whole
  # deadline (a bare test, Checkpoint's own git calls).
  defp wake_timeout(deadline, nil), do: remaining(deadline)
  defp wake_timeout(deadline, _session_id), do: min(remaining(deadline), @poll_ms)

  # A user stop wins over the deadline; otherwise the deadline kills the
  # command (its own timeout), and a false wake just re-arms the receive.
  defp on_wake(port, deadline, state, cut, session_id) do
    cond do
      session_id && Interrupt.requested?(session_id) ->
        kill(port)
        {:stopped, finish(state, cut)}

      remaining(deadline) <= 0 ->
        kill(port)
        {:timeout, finish(state, cut)}

      true ->
        collect(port, deadline, state, cut, session_id)
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

  @doc """
  Formats a tool result for the model: the command, a status line, and
  the combined output.
  """
  @spec format(
          String.t(),
          String.t(),
          {:exit, integer()} | :timeout | :stopped | :raw_too_large,
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
        :stopped -> "STOPPED by the user (output below is partial)"
        :raw_too_large -> "output too large to buffer; narrow the command"
      end

    """
    $ #{command}
    #{status_line}, took #{div(elapsed_ms, 1000)}s
    --- output ---
    #{if output == "", do: "(no output)", else: output}\
    """
  end
end
