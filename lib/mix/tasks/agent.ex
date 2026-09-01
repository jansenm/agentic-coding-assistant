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
    finish_turn(id, result)
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
            result = CodingAgent.Core.Session.run(id, trimmed)
            flush_deltas()
            finish_turn(id, result)
            loop(id)
        end
    end
  end

  # Follow a turn to completion: print final answers; resolve
  # permission-gate interruptions (ADR 010 stdin y/e/n/a stub — the
  # real TUI approval flow is phase 4) and continue until the turn
  # reaches a final state. Plain one-driver-for-all-modes: neither the
  # one-shot nor the chat path may ever block on internal messages.
  defp finish_turn(_id, {:error, reason}) do
    print_error(reason)
  end

  defp finish_turn(id, {:ok, %{status: :interrupted} = state}) do
    decisions = ask_decisions(state.pending_tool_calls)

    case CodingAgent.Core.Session.decide(id, decisions) do
      {:ok, state2} ->
        flush_deltas()
        finish_turn(id, {:ok, state2})

      {:error, reason} ->
        print_error(reason)
    end
  end

  defp finish_turn(_id, {:ok, state}) do
    print_result({:ok, state})
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

  # Edit pending args at the approval prompt, generically: for every
  # key in the call's arguments, empty input keeps the current value.
  # (write_file's path/content, edit's old_string/new_string, shell's
  # command/timeout_secs — all handled the same way.)
  defp do_edit(args) when args == %{}, do: args

  defp do_edit(args) do
    Enum.reduce(args, args, fn {key, current}, acc ->
      case IO.gets("  #{key} [#{current}] > ") do
        :eof ->
          acc

        line ->
          case String.trim(line) do
            "" -> acc
            new_value -> Map.put(args, key, new_value)
          end
      end
    end)
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
