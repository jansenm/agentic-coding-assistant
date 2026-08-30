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

    {opts, args} =
      OptionParser.parse!(args, strict: [chat: :boolean], aliases: [c: :chat])

    chat? = opts[:chat] == true

    case {chat?, args} do
      {true, []} -> chat_loop()
      {true, _} -> Mix.raise("usage: mix agent --chat (no prompt arguments)")
      {false, [prompt]} -> one_shot(prompt)
      {false, []} -> Mix.raise("usage: mix agent \"prompt\" | mix agent --chat")
    end
  end

  defp one_shot(prompt) do
    id = session_id()
    {:ok, _pid} = CodingAgent.Core.Session.Supervisor.start_session(id: id)
    CodingAgent.Core.Session.subscribe(id)

    # Streamed deltas already arrive in this process' mailbox while
    # run/2 blocks; drain them after the turn completes (the deltas
    # were printed by whoever consumed them — mixing drain and stream
    # display is the UI's job in phase 4; here we print the final text).
    result = CodingAgent.Core.Session.run(id, prompt)
    flush_deltas()
    print_result(result)
  end

  defp chat_loop do
    id = session_id()
    {:ok, _pid} = CodingAgent.Core.Session.Supervisor.start_session(id: id)
    CodingAgent.Core.Session.subscribe(id)

    IO.puts("Interactive session #{id} — empty line or Ctrl-D to exit.\n")

    loop(id)
  end

  defp loop(id) do
    case IO.gets(prompt_string()) do
      :eof ->
        IO.puts("")
        :ok

      {:error, _} ->
        IO.puts("")
        :ok

      line ->
        case String.trim(line) do
          "" ->
            IO.puts("")
            :ok

          trimmed ->
            case CodingAgent.Core.Session.run(id, trimmed) do
              {:ok, state} ->
                flush_deltas()
                handle_turn(id, state)
                loop(id)

              {:error, reason} ->
                print_error(reason)
                loop(id)
            end
        end
    end
  end

  # An interrupted turn (permission gate) runs the approval loop (ADR 010
  # stub: stdin y/e/n); the real TUI approval flow is phase 4.
  defp handle_turn(_id, %{status: :interrupted} = state) do
    decisions = ask_decisions(state.pending_tool_calls)

    # caller loop drives the next turn; here we only resolve approval
    case decisions do
      nil -> :aborted
      decisions -> send(self(), {:__decide__, decisions})
    end
  end

  defp handle_turn(id, state) do
    print_result({:ok, state})

    receive do
      {:__decide__, decisions} ->
        case CodingAgent.Core.Session.decide(id, decisions) do
          {:ok, state2} ->
            flush_deltas()
            handle_turn(id, state2)

          {:error, reason} ->
            print_error(reason)
        end
    end
  end

  defp ask_decisions(pending) do
    Enum.map(pending, &ask_decision/1)
  end

  defp ask_decision(call) do
    {id, name, args} = call_info(call)
    args_str = Jason.encode!(args)

    IO.puts("\n[approval needed] #{name}(#{args_str})")

    answer =
      case IO.gets("  [y]es / [e]dit / [n]o / [a]bort > ")
           |> String.trim()
           |> String.downcase() do
        "y" -> :approve
        "e" -> :edit
        "n" -> :reject
        "a" -> exit({:shutdown, 130})
        _ -> :reject
      end

    final =
      if answer == :edit do
        new_args = do_edit(args)
        %{id: id, decision: {:edit, new_args}}
      else
        %{id: id, decision: answer}
      end

    final
  end

  defp do_edit(args) do
    new_path = IO.gets("  path [#{args["path"]}] > ") |> String.trim()
    new_content = IO.gets("  content (single line) > ") |> String.trim()

    args
    |> Map.put("path", if(new_path == "", do: args["path"], else: new_path))
    |> Map.put("content", if(new_content == "", do: args["content"], else: new_content))
  end

  defp session_id, do: "cli-#{System.unique_integer([:positive])}"

  defp prompt_string, do: IO.ANSI.faint() <> "> " <> IO.ANSI.reset()

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
        last =
          state.context
          |> ReqLLM.Context.to_list()
          |> Enum.reverse()
          |> Enum.find(&(&1.role == :assistant))

        if last, do: IO.puts("\n" <> text_of(last) <> "\n")

      :interrupted ->
        IO.puts("\n[tool calls pending]")
    end
  end

  defp print_result({:error, {:missing_api_key, env_var}}) do
    print_error({:missing_api_key, env_var})
  end

  defp print_result({:error, reason}) do
    print_error(reason)
  end

  defp print_error({:missing_api_key, env_var}) do
    IO.puts("No API key configured. Set #{env_var} (env var or .env file).")
    exit({:shutdown, 1})
  end

  defp print_error(reason) do
    IO.puts("[error] #{inspect(reason)}")
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

  # Tool calls arrive in two shapes (ReqLLM.ToolCall struct with JSON
  # arguments, or plain map from stream events) — normalize like the
  # session's call_parts/1.
  defp call_info(%ReqLLM.ToolCall{id: id, function: %{name: name, arguments: args}}) do
    {id, name, decode_args(args)}
  end

  defp call_info(%{id: id, name: name, arguments: args}) when is_map(args) do
    {id, name, args}
  end

  defp call_info(%{id: id, name: name}), do: {id, name, %{}}

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp decode_args(args) when is_map(args), do: args
end
