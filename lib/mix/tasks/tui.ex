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

    {opts, args} =
      OptionParser.parse!(args, strict: [resume: :string], aliases: [r: :resume])

    prompt =
      case args do
        [p] -> p
        _ -> nil
      end

    tui_opts =
      [initial_prompt: prompt, scope_root: File.cwd!(), mouse_capture: true]
      |> maybe_resume(opts[:resume])

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
end
