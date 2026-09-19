defmodule Mix.Tasks.Tui do
  @moduledoc """
  The phase-5 terminal UI (5a slice).

      mix tui                          # fresh session, empty transcript
      mix tui "run the test suite"     # fresh session + initial prompt
      mix tui --resume <id>            # continue a persisted session
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
        strict: [resume: :string, agent: :string],
        aliases: [r: :resume]
      )

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

    {:ok, _} = CodingAgent.UI.Tui.start_link(tui_opts)

    # The app runs supervised; keep this process alive while the TUI is up
    ref =
      case Process.whereis(CodingAgent.UI.Tui) do
        nil -> self()
        pid -> Process.monitor(pid)
      end

    receive do
      {:DOWN, ^ref, _, _, _} ->
        # the TUI stopped (q / ctrl-c): shut the BEAM down. Without this
        # the Mix VM lingers at an iex-like prompt — supervised trees and
        # the logger keep the scheduler alive after the task returns.
        System.halt(0)
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

    def log(event, %{config: %{file: file}}) do
      # ~p on the message: logger msg may be chardata with embedded
      # atoms/terms — ~ts would crash on atoms, ~p prints anything
      line =
        case event[:msg] do
          m when is_binary(m) -> :io_lib.format("~ts [~p] ~ts~n", [ts(), event[:level], m])
          m -> :io_lib.format("~ts [~p] ~p~n", [ts(), event[:level], m])
        end

      File.write(file, line, [:append])
    end

    defp ts, do: Calendar.strftime(NaiveDateTime.local_now(), "%H:%M:%S")
  end

  defp log_path do
    dir = CodingAgent.Core.Config.state_dir()
    File.mkdir_p!(dir)
    Path.join(dir, "tui.log")
  end
end
