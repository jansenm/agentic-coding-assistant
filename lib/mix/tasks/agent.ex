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

        # Streamed deltas already arrive in this process' mailbox while
        # run/2 blocks; drain them after the turn completes (the deltas
        # were printed by whoever consumed them — mixing drain and stream
        # display is the UI's job in phase 4; here we print the final text).
        result = CodingAgent.Core.Session.run(id, prompt)
        flush_deltas()
        print_result(result)

      _ ->
        Mix.raise("usage: mix agent \"prompt\"")
    end
  end

  defp flush_deltas do
    receive do
      {:agent, {:llm_deltas, _delta}} -> flush_deltas()
      {:agent, _event} -> flush_deltas()
    after
      0 -> :ok
    end
  end

  defp print_result({:ok, state}) do
    case state.status do
      :idle ->
        last = Enum.reverse(ReqLLM.Context.to_list(state.context)) |> List.first()
        IO.puts("\n" <> text_of(last) <> "\n")

      :interrupted ->
        IO.puts("\n[tool calls requested — tool subsystem arrives in phase 2]")

        Enum.each(state.pending_tool_calls, fn call ->
          IO.puts("  -> #{call.function.name}(#{call.function.arguments})")
        end)
    end
  end

  defp print_result({:error, {:missing_api_key, env_var}}) do
    IO.puts("No API key configured. Set #{env_var} (env var or .env file).")
    exit({:shutdown, 1})
  end

  defp print_result({:error, reason}) do
    IO.puts("[error] #{inspect(reason)}")
    exit({:shutdown, 1})
  end

  defp text_of(%ReqLLM.Message{content: content}) when is_binary(content), do: content

  defp text_of(%ReqLLM.Message{content: parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %ReqLLM.Message.ContentPart{type: :text, text: text} -> text
      part -> inspect(part)
    end)
    |> Enum.join("")
  end
end
