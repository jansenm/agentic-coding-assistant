defmodule Mix.Tasks.Agent do
  @moduledoc """
  Minimal phase-1 harness: one-shot prompt from argv, streamed answer
  to stdout.

      mix agent "explain this error: ..."
      ANTHROPIC_API_KEY=sk-... mix agent "hello"
  """

  use Mix.Task

  @shortdoc "Run one coding-agent turn from the command line"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start", [])

    case args do
      [prompt] ->
        id = "cli-#{System.unique_integer([:positive])}"
        {:ok, _pid} = CodingAgent.Core.Session.Supervisor.start_session(id: id)
        CodingAgent.Core.Session.subscribe(id)

        case CodingAgent.Core.Session.run(id, prompt) do
          {:ok, state} ->
            case state.status do
              :idle ->
                IO.puts("\n")

              :interrupted ->
                IO.puts("\n[tool calls requested — tool subsystem arrives in phase 2]")

                Enum.each(state.pending_tool_calls, fn call ->
                  IO.puts("  -> #{call.function.name}(#{call.function.arguments})")
                end)
            end

          {:error, {:missing_api_key, env_var}} ->
            IO.puts("""
            No API key configured. Set #{env_var} (env var or .env file).
            """)

            exit({:shutdown, 1})

          {:error, reason} ->
            IO.puts("\n[error] #{inspect(reason)}")
            exit({:shutdown, 1})
        end

      _ ->
        Mix.raise("usage: mix agent \"prompt\"")
    end
  end
end