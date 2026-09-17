defmodule Mix.Tasks.Agent do
  @moduledoc """
  Minimal phase-1 harness, extended in 4a with session persistence:
  one-shot prompt from argv, streamed answer to stdout.

      mix agent "explain this error: ..."
      mix agent --chat                  # multi-turn session
      mix agent --sessions              # list persisted sessions (with paths)
      mix agent --resume <id>           # continue a persisted session
      mix agent --session-delete <id>   # delete one session
      mix agent --session-prune <days>  # delete sessions older than N days
  """

  use Mix.Task

  @shortdoc "Run one coding-agent turn from the command line"

  @impl Mix.Task
  def run(args) do
    # Unix pipe hygiene: `mix agent --sessions | less` gets :epipe when
    # the reader (less) exits before us. Catch the io error and exit
    # cleanly instead of dumping an ErlangError stack trace.
    try do
      run_uncatched(args)
    rescue
      e in ErlangError ->
        case e.reason do
          :terminated -> exit({:shutdown, 0})
          _ -> reraise e, __STACKTRACE__
        end
    end
  end

  defp run_uncatched(args) do
    Mix.Task.run("app.start", [])

    {opts, args} =
      OptionParser.parse!(args,
        strict: [
          chat: :boolean,
          resume: :string,
          agent: :string,
          sessions: :boolean,
          session_delete: :string,
          session_prune: :integer
        ],
        aliases: [c: :chat, r: :resume]
      )

    chat? = opts[:chat] == true
    resume_id = opts[:resume]
    agent = opts[:agent]
    list? = opts[:sessions] == true
    delete_id = opts[:session_delete]
    prune_days = opts[:session_prune]

    cond do
      list? ->
        list_sessions()

      is_binary(delete_id) ->
        delete_session(delete_id)

      is_integer(prune_days) ->
        prune_sessions(prune_days)

      is_binary(resume_id) and args == [] ->
        chat_loop(resume_id, agent)

      is_binary(resume_id) ->
        Mix.raise("usage: mix agent --resume <id> (no prompt arguments)")

      chat? and args == [] ->
        chat_loop(nil, agent)

      chat? ->
        Mix.raise("usage: mix agent --chat (no prompt arguments)")

      is_list(args) and length(args) == 1 ->
        one_shot(hd(args), agent)

      true ->
        Mix.raise(
          "usage: mix agent \"prompt\" | mix agent --chat | " <>
            "mix agent --agent <name> | " <>
            "mix agent --sessions | mix agent --resume <id> | " <>
            "mix agent --session-delete <id> | mix agent --session-prune <days>"
        )
    end
  end

  # -- Sessions (slice 4a) ----------------------------------------------------

  defp list_sessions do
    case CodingAgent.Core.Session.Store.list() do
      [] ->
        IO.puts("No persisted sessions.")

      sessions ->
        IO.puts("Persisted sessions (newest first):\n")

        Enum.each(sessions, fn s ->
          time = Calendar.strftime(s.saved_at, "%Y-%m-%d %H:%M")
          file = CodingAgent.Core.Session.Store.path(s.id)

          IO.puts(
            "  #{s.id}  #{time}  #{s.status}  #{s.model || "?"}\n" <>
              "      #{file} (#{file_size(file)})"
          )
        end)
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> "#{size} bytes"
      {:error, _} -> "?"
    end
  end

  # Lifecycle verbs (session-storage principle 3): cleanup is a CLI
  # operation, never file archaeology.
  defp delete_session(id) do
    case CodingAgent.Core.Session.Store.load(id) do
      {:ok, _} ->
        :ok = CodingAgent.Core.Session.Store.delete(id)
        IO.puts("Deleted session #{id} (#{CodingAgent.Core.Session.Store.path(id)}).")

      {:error, reason} ->
        print_error(reason)
    end
  end

  defp prune_sessions(days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400)

    {deleted, kept} =
      Enum.split_with(CodingAgent.Core.Session.Store.list(), &(&1.saved_at < cutoff))

    Enum.each(deleted, fn s ->
      :ok = CodingAgent.Core.Session.Store.delete(s.id)
      IO.puts("Pruned #{s.id} (saved #{Calendar.strftime(s.saved_at, "%Y-%m-%d %H:%M")}).")
    end)

    IO.puts("#{length(deleted)} pruned, #{length(kept)} kept.")
  end

  defp one_shot(prompt, agent) do
    id = session_id()
    {:ok, _pid} = CodingAgent.Core.Session.Supervisor.start_session(id: id, agent: agent)
    CodingAgent.Core.Session.subscribe(id)

    # Streamed deltas already arrive in this process' mailbox while
    # run/2 blocks; drain them after the turn completes (the deltas
    # were printed by whoever consumed them — mixing drain and stream
    # display is the UI's job in phase 4; here we print the final text).
    result = CodingAgent.Core.Session.run(id, prompt)
    flush_deltas()
    finish_turn(id, result)
  end

  defp chat_loop(nil, agent) do
    id = session_id()
    {:ok, _pid} = CodingAgent.Core.Session.Supervisor.start_session(id: id, agent: agent)
    CodingAgent.Core.Session.subscribe(id)

    IO.puts("""
    Interactive session #{id} — empty line or Ctrl-D to exit.

    Note (CLI limitation): a multi-line PASTE at the prompt queues the
    extra lines in the terminal; they surface as stray answers at the
    next approval prompt (repeating "(answer y/e/n/a)" lines). Paste
    tasks as a single line, or expect a couple of ignored re-prompts.
    The phase-4 TUI reads proper multi-line input.
    """)

    loop(id)
  end

  # Resume: load the persisted state and continue the conversation.
  defp chat_loop(resume_id, agent) when is_binary(resume_id) do
    resolved =
      case CodingAgent.Core.Session.Store.resolve_id(resume_id) do
        {:ok, full_id} ->
          {:ok, full_id}

        {:error, :enoent} = e ->
          e

        {:error, {:ambiguous_id, many}} = e ->
          IO.puts("Ambiguous session id \"#{resume_id}\" — candidates:")
          Enum.each(many, &IO.puts("  #{&1}"))
          e
      end

    case resolved do
      {:ok, persisted} ->
        opts = [
          id: persisted.id,
          context: persisted.context,
          model: persisted.model,
          scope_root: persisted.scope_root,
          policy: persisted.policy,
          # restore the agent name for the UI/carried policy; an explicit
          # --agent overrides the persisted one (a deliberate switch)
          agent: agent || (persisted.agent && persisted.agent.name),
          # carry the persisted usage forward or the session takes the
          # chars fallback and compacts on the first command
          usage: persisted.usage,
          compaction_warned: persisted.compaction_warned,
          compaction_backoff: persisted.compaction_backoff,
          # resume a gate-parked session parked (pending calls + the
          # round half already decided survive the restart)
          status: persisted.status,
          pending_tool_calls: persisted.pending_tool_calls,
          pending_round_calls: persisted.pending_round_calls,
          pending_round_results: persisted.pending_round_results
        ]

        {:ok, _pid} = CodingAgent.Core.Session.Supervisor.start_session(opts)
        CodingAgent.Core.Session.subscribe(persisted.id)

        IO.puts("""
        Resumed session #{persisted.id} (#{length(ReqLLM.Context.to_list(persisted.context))} messages in context).
        """)

        # A session parked at the gate when it stopped resumes PARKED.
        # Resolve that round before prompting for new input, or the
        # pending calls (and the auto-executed half of the round) would
        # sit stranded in state while the user types a new prompt.
        case CodingAgent.Core.Session.state(persisted.id) do
          {:ok, %{status: :interrupted} = state} ->
            finish_turn(persisted.id, {:ok, state})

          _ ->
            :ok
        end

        loop(persisted.id)

      {:error, reason} ->
        print_error(reason)
        IO.puts("\nUse `mix agent --sessions` to list persisted sessions.")
    end
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

    IO.puts("""

    ┌─ APPROVAL REQUESTED ─────────────────────────────
    │ tool:  #{name}
    │ args:  #{args_str}
    └─ Do you approve? (y = yes, e = edit args, n = no, a = abort)
    """)

    loop_decision(id, args)
  end

  # Re-prompts on unrecognized input — silently rejecting a tool call
  # because the user typed prose ("apply as is") is the worst fallback:
  # it looks like a harness bug from the model's side. Ctrl-D/Ctrl-C
  # remain the abort paths.
  defp loop_decision(id, args) do
    case IO.gets("  [y]es / [e]dit / [n]o / [a]bort > ") do
      :eof ->
        IO.puts("")
        exit({:shutdown, 130})

      {:error, _} ->
        exit({:shutdown, 130})

      line ->
        case String.trim(line) |> String.downcase() do
          "y" ->
            %{id: id, decision: :approve}

          "e" ->
            %{id: id, decision: {:edit, do_edit(args)}}

          "n" ->
            %{id: id, decision: :reject}

          "a" ->
            exit({:shutdown, 130})

          _ ->
            IO.puts("  (answer y / e / n / a — other input is ignored)")
            loop_decision(id, args)
        end
    end
  end

  # Edit pending args at the approval prompt, generically: for every
  # key in the call's arguments, empty input keeps the current value.
  # Multiline values (edit's old_string/new_string, write_file's
  # content) cannot be entered in a line-based prompt — they are shown
  # read-only with a notice; editing those is phase-4 TUI material.
  defp do_edit(args) when args == %{}, do: args

  defp do_edit(args) do
    Enum.reduce(args, args, fn {key, current}, acc ->
      if String.contains?(to_string(current), "\n") do
        IO.puts("  #{key}: (multiline — editing not supported in this CLI stub; Enter keeps)")
        IO.puts("    " <> String.replace(to_string(current), "\n", "\n    "))
        acc
      else
        case IO.gets("  #{key} [#{current}] > ") do
          :eof ->
            acc

          line ->
            case String.trim(line) do
              "" -> acc
              new_value -> Map.put(args, key, new_value)
            end
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

  # End-of-turn framing. A model question and a final answer look the
  # same as bare text; without framing the user cannot tell "done"
  # from "the agent is waiting for me" (live feedback, dogfood pass 3).
  defp print_result({:ok, state}) do
    case state.status do
      :idle ->
        last =
          state.context
          |> ReqLLM.Context.to_list()
          |> Enum.reverse()
          |> Enum.find(&(&1.role == :assistant))

        if last do
          IO.puts("\n" <> text_of(last) <> "\n")

          IO.puts(
            IO.ANSI.faint() <>
              "— turn complete. Type your reply at the prompt. —" <> IO.ANSI.reset()
          )
        end

      :interrupted ->
        IO.puts(
          "\n" <>
            IO.ANSI.faint() <> "[agent paused — YOUR decision is needed below]" <> IO.ANSI.reset()
        )
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
