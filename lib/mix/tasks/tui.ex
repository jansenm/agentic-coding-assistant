defmodule Mix.Tasks.Tui do
  @moduledoc """
  The phase-5 terminal UI (5a slice).

      mix tui                          # fresh session, empty transcript
      mix tui "run the test suite"     # fresh session + initial prompt
      mix tui --resume <id>            # continue a persisted session
      mix tui --store <name|path>      # use a specific session store

  The session store (ADR 020 R16) is a directory; `--store` names one
  from config.toml `[stores]` or gives a path (`AGENT_STORE` and
  `config.toml store =` do the same without the flag).
  """

  use Mix.Task

  @shortdoc "Run the coding-agent terminal UI"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start", [])

    # Defensive terminal reset BEFORE anything is printed. If a previous
    # run died without cleanup — ex_ratatui restores the terminal in
    # `restore_terminal/1` and `Drop for TerminalResource`, and a native
    # crash (SIGSEGV in the NIF, seen 2026-09-19) runs neither — the tty
    # is left in the alternate screen, raw mode, and mouse-capture on.
    # The next `EnterAlternateScreen` is then a no-op on an already-
    # alternate screen, so the new frame paints OVER whatever text was
    # there and the mouse keeps reporting (tmux selection breaks). Emit
    # the leave/reset sequences first so each start begins clean.
    reset_terminal()

    # Console logging paints OVER the alternate screen: every warning
    # corrupts the diff-rendered frame (found live: req_llm transport
    # retries dumped raw logs over the transcript, status line and
    # input box). The TUI owns the screen while it runs — logs go to
    # a file instead.
    log_path = log_path()
    :logger.remove_handler(:default)

    :logger.add_handler(:coding_agent_tui, __MODULE__.Handler, %{
      config: %{file: log_path, type: :raw}
    })

    Mix.shell().info("logs: #{log_path}")

    {opts, args} =
      OptionParser.parse!(args,
        strict: [resume: :string, agent: :string, store: :string],
        aliases: [r: :resume]
      )

    # Pin the store before the TUI mounts: the picker, the log path and
    # every session read `Store.path/0` (the flag, else AGENT_STORE/config).
    CodingAgent.Core.Config.select_store!(opts[:store])

    prompt =
      case args do
        [p] -> p
        _ -> nil
      end

    tui_opts =
      [initial_prompt: prompt, scope_root: File.cwd!(), mouse_capture: true]
      |> maybe_resume(opts[:resume])
      |> maybe_agent(opts[:agent])

    if CodingAgent.model() == nil do
      Mix.raise(CodingAgent.Core.Config.no_model_message())
    end

    {:ok, tui} = CodingAgent.UI.Tui.start_link(tui_opts)
    await_tui(tui)
  end

  # Wait for the TUI to stop, then take the VM down with it. Public (with
  # the one-line halt injected) so the line that matters is testable: the
  # pid to monitor is the one `start_link/1` RETURNED, never a name.
  # `use ExRatatui.App` generates `start_link/1` as `dispatch_start/1` into
  # `ExRatatui.Server`, whose default registered name is
  # `ExRatatui.Server` — `CodingAgent.UI.Tui` is a callback module, never a
  # process. The old `Process.whereis(CodingAgent.UI.Tui)` was therefore
  # always nil, so it fell back to `self()` and no `:DOWN` ever arrived:
  # `q` stopped the TUI and the VM lingered at an iex-like prompt — the
  # exact symptom this wait exists to prevent (review N88).
  @doc false
  def await_tui(tui, halt \\ &System.halt/1) do
    ref = Process.monitor(tui)

    receive do
      {:DOWN, ^ref, _, _, _} ->
        # the TUI stopped (q / ctrl-c): shut the BEAM down. Without this
        # the Mix VM lingers at an iex-like prompt — supervised trees and
        # the logger keep the scheduler alive after the task returns.
        halt.(0)
    end
  end

  # Leave whatever state a crashed predecessor left behind, then clear.
  # Ordered: disable the input modes first, then leave the alternate
  # screen (which restores the original screen content and cursor), then
  # clear it as a belt-and-braces for a terminal that ignored one of the
  # sequences. Written to the controlling tty (`/dev/tty`) so it lands
  # even when stdout is redirected; best-effort — a terminal that is
  # already clean just sees harmless no-ops.
  #
  #   ?1000l ?1002l ?1003l ?1006l  disable mouse reporting (all modes)
  #   ?1004l                      disable focus reporting
  #   ?2004l                      disable bracketed paste
  #   ?1049l                      leave alternate screen
  #   ?25h                        show the cursor
  #   ESC[2J ESC[H                clear screen, home
  defp reset_terminal do
    case File.open("/dev/tty", [:write, :raw]) do
      {:ok, tty} ->
        IO.binwrite(
          tty,
          "\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1004l\e[?2004l\e[?1049l\e[?25h\e[2J\e[H"
        )

        File.close(tty)

      {:error, _} ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_resume(tui_opts, nil), do: tui_opts
  defp maybe_resume(tui_opts, id), do: Keyword.put(tui_opts, :resume_id, id)

  defp maybe_agent(tui_opts, nil), do: Keyword.put(tui_opts, :agent, "build")
  defp maybe_agent(tui_opts, name), do: Keyword.put(tui_opts, :agent, name)

  # Minimal :logger file handler (OTP logger, not the deprecated
  # Logger backends): one line per event, no truncation games.
  defmodule Handler do
    @moduledoc false

    # `msg` is NEVER a bare binary: OTP hands a handler one of
    # `{:string, chardata}`, `{format, args}` or `{:report, term}`. The old
    # `is_binary/1` guard matched none of them, so every event went through
    # `~p` — and `~p` renders a binary as text only while every byte is
    # printable-latin1. A single UTF-8 continuation byte (128..191) flips it
    # to a comma-separated byte list: the context warning's em dash
    # (226,128,148) turned one line into nineteen. Dispatch on the shapes
    # that exist and render text as text.
    #
    # Two promises this keeps. One PHYSICAL line per event: `~p` also wraps
    # at a fixed column, and a message may carry newlines of its own — both
    # are escaped. And it never raises: OTP REMOVES a raising handler
    # (`removed_failing_handler`), after which the TUI logs nowhere at all.
    def log(event, %{config: %{file: file}}) do
      File.write(file, [ts(), " [", level(event[:level]), "] ", message(event[:msg]), "\n"], [
        :append
      ])

      :ok
    rescue
      e ->
        File.write(
          file,
          "#{ts()} [error] tui log handler failed: #{Exception.message(e)}\n",
          [:append]
        )

        :ok
    end

    defp message(msg) do
      case msg do
        {:string, text} -> text(text)
        {format, args} when is_list(args) -> text(:io_lib.format(format, args))
        other -> inspect(other, limit: :infinity, printable_limit: :infinity)
      end
    rescue
      # a malformed format string must not cost the event
      _ -> inspect(msg, limit: :infinity, printable_limit: :infinity)
    end

    # chardata — a binary, a charlist or arbitrarily nested — to one UTF-8
    # binary. `characters_to_binary/1` returns the part it could convert for
    # invalid UTF-8; render that remainder as a byte string rather than
    # dropping the event.
    defp text(chardata) do
      case :unicode.characters_to_binary(chardata) do
        bin when is_binary(bin) -> one_line(bin)
        {_error, _converted, rest} -> inspect(rest)
      end
    end

    defp one_line(bin) do
      bin
      |> :binary.replace("\r", "\\r", [:global])
      |> :binary.replace("\n", "\\n", [:global])
    end

    defp level(level), do: to_string(level)

    defp ts, do: Calendar.strftime(NaiveDateTime.local_now(), "%H:%M:%S")
  end

  defp log_path do
    dir = CodingAgent.Core.Config.state_dir()
    File.mkdir_p!(dir)
    Path.join(dir, "tui.log")
  end
end
