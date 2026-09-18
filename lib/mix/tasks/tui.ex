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
