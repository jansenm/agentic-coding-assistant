defmodule CodingAgent.Core.Session.Subagent do
  @moduledoc """
  The `task` seam: delegate to a child session and return only its
  summary (ADR 017/018).

  A `task` call is intercepted by the parent's session before the gate
  runs (`Session.execute_round/3`), because a child needs the parent's
  RESOLVED config (model, policy, mounts) and must be bounded in depth.
  This module owns every part of that exchange:

    * find the named `subagent_type` definition (a `:subagent` or `:all`
      definition, never a `primary`; ADR 029);
    * start a child `Session` with an isolated context, the parent's
      policy (so the child can only narrow further), `depth: parent +
      1`, `interactive: false` (no human channel) and `persist?: false`
      (the summary is the record, not a picker entry);
    * broadcast `{:subagent_started, child_id, name, model}` on the
      PARENT's channel, run the child, extract its final assistant text,
      and broadcast `{:subagent_finished, child_id, outcome}`;
    * delete the child's ephemeral store rows.

  The invariant (ADR 018): the child's transcript NEVER enters the
  parent's context. Only the returned summary does, as the `task` tool
  result.

  Depth is 1: the child's tool scope excludes `task`, so it cannot
  delegate again.
  """

  alias CodingAgent.Core.{Agent, Config, ToolCall}
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.State

  @max_depth 1

  # Appended to the caller's prompt so the child reliably returns a
  # summary: the parent context carries ONLY this text, never the child's
  # transcript (ADR 018). Our wording; opencode's task tool is the
  # reference shape, not the source.
  @summary_instruction """


  Finish by replying with a concise summary of what you found and the
  answer to the task. Your final message is the ONLY thing returned to
  the caller — it never sees your work, your reasoning, or your tool
  calls, so put everything that matters in the summary.\
  """

  @typedoc "A task tool result, ready for the round's exchange."
  @type result :: %{id: String.t(), name: String.t(), content: String.t()}

  @doc """
  Runs one `task` call. Every handled failure (unknown type, a refused
  primary, a failed or summary-less child) returns a result carrying an
  error string, so the parent model can correct itself instead of the
  turn crashing. An UNEXPECTED raise inside this function (it loads
  definitions and reads a child state) is contained one level up:
  `run_subagents/2` runs these under a supervisor and turns the task
  exit into the same error-result shape.
  """
  @spec run(State.t(), term()) :: result()
  def run(%State{} = parent, call) do
    {id, name, args} = ToolCall.normalize(call)

    result =
      with :ok <- depth_ok(parent),
           {:ok, type} <- fetch_type(args),
           {:ok, definition} <- find_definition(parent, type) do
        delegate(parent, definition, args)
      end

    case result do
      {:ok, summary} -> %{id: id, name: name, content: summary}
      {:error, reason} -> %{id: id, name: name, content: "error: #{reason}"}
    end
  end

  # -- The delegation ---------------------------------------------------------

  defp delegate(parent, definition, args) do
    prompt = (arg(args, "prompt") || "") <> @summary_instruction
    child_id = child_id(parent)
    model = child_model(parent, definition)

    case start_child(parent, child_id, definition) do
      {:ok, _pid} ->
        # The child's event lifecycle is started -> finished, ALWAYS: a
        # subscriber (the TUI tab) keeps the tab "running" until the
        # finish event, and `cleanup/1` retires the child session. An
        # unexpected raise while reading the child's result (e.g.
        # `summarize/1` on a corrupted state) must not skip either —
        # nolink containment in `run_subagents/2` handles exits/kills,
        # this rescue handles exceptions.
        try do
          announce_started(parent, child_id, definition.name, model)

          outcome = run_child(child_id, prompt)
          summary = summarize(outcome)
          announce_finished(parent, child_id, if(match?({:ok, _}, outcome), do: :ok, else: :error))
          summary
        rescue
          e ->
            announce_finished(parent, child_id, :error)
            {:error, "subagent crashed: #{Exception.message(e)}"}
        after
          cleanup(child_id)
        end

      {:error, reason} ->
        {:error, "could not start subagent #{inspect(definition.name)}: #{inspect(reason)}"}
    end
  end

  # A crashed child (a `:noproc` exit, a worker crash) must not take the
  # PARENT's turn worker down with it: it becomes an error result, like a
  # failed tool call. `Session.run/2` is `:infinity` and can exit if the
  # child process died mid-call.
  defp run_child(child_id, prompt) do
    Session.run(child_id, prompt)
  catch
    :exit, reason -> {:error, {:subagent_exit, reason}}
  end

  defp start_child(parent, child_id, definition) do
    Session.Supervisor.start_session(
      id: child_id,
      scope_root: parent.scope_root,
      # the parent's (already agent-narrowed) policy: the child can only
      # narrow further, never widen — a plan parent cannot grant build
      policy: parent.policy,
      # the running model; the definition's own `model` wins in
      # State.effective_model/1 (ADR 017 precedence: definition > session)
      model: State.effective_model(parent),
      agent: definition.name,
      interactive: false,
      # test_mode propagates: a child of a test session must never reach a
      # provider (the suite is LLM-free); its blocking body comes from the
      # parent's `subagent_runner` seam
      test_mode: parent.test_mode,
      depth: parent.depth + 1,
      persist?: false,
      turn_runner: parent.subagent_runner
    )
  end

  # The model the child will actually run (for the UI event): the
  # definition's pinned model when set, else the parent's effective model.
  defp child_model(_parent, %Agent{model: model}) when is_binary(model) and model != "", do: model
  defp child_model(parent, _definition), do: State.effective_model(parent)

  # -- The result -------------------------------------------------------------

  # The child's own turn result: its final assistant text is the summary.
  # `Session.run/2` returns the whole state, and the answer is the last
  # assistant message in its context.
  defp summarize({:ok, %State{} = child}) do
    case last_assistant_text(child) do
      nil when child.status == :error ->
        {:error, "subagent failed: #{inspect(child.last_error)}"}

      nil ->
        {:error, "subagent produced no summary"}

      text ->
        {:ok, text}
    end
  end

  defp summarize({:error, reason}), do: {:error, "subagent failed: #{inspect(reason)}"}

  defp last_assistant_text(%State{context: context}) do
    context
    |> ReqLLM.Context.to_list()
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ReqLLM.Message{role: :assistant, content: content} -> message_text(content)
      _ -> nil
    end)
  end

  defp message_text(content) when is_binary(content) do
    if String.trim(content) == "", do: nil, else: content
  end

  defp message_text(parts) when is_list(parts) do
    text =
      parts
      |> Enum.map(fn
        %ReqLLM.Message.ContentPart{text: t} when is_binary(t) -> t
        _ -> ""
      end)
      |> Enum.join("")

    if String.trim(text) == "", do: nil, else: text
  end

  defp message_text(_), do: nil

  # -- Definitions ------------------------------------------------------------

  defp find_definition(parent, type) do
    case Config.agents(parent.scope_root) do
      {:ok, definitions} ->
        case Enum.find(definitions, &(&1.name == type)) do
          nil ->
            names = delegatable(definitions) |> Enum.map(& &1.name)
            {:error, "unknown subagent #{inspect(type)}; available: #{Enum.join(names, ", ")}"}

          %Agent{mode: :primary} ->
            {:error, "#{inspect(type)} is a primary agent; it cannot be delegated to"}

          definition ->
            {:ok, definition}
        end

      {:error, errors} ->
        {:error, "cannot load agent definitions: #{Enum.join(errors, "; ")}"}
    end
  end

  @doc """
  The names a `task` call may delegate to: `:subagent` and `:all`
  definitions (a `primary` is for the human; `hidden` is allowed — ADR
  029 says the seam needs exactly that for internal agents).
  """
  @spec delegatable([Agent.t()]) :: [Agent.t()]
  def delegatable(definitions) do
    Enum.filter(definitions, &(&1.mode in [:subagent, :all]))
  end

  defp depth_ok(%State{depth: depth}) when depth >= @max_depth do
    {:error, "subagents may not start further subagents (depth #{@max_depth})"}
  end

  defp depth_ok(_parent), do: :ok

  # -- Events -----------------------------------------------------------------

  defp announce_started(parent, child_id, name, model) do
    CodingAgent.Core.Events.publish(parent.id, {:subagent_started, child_id, name, model})
    CodingAgent.Core.Events.publish(parent.id, {:info, "· subagent #{name} started"})
  end

  defp announce_finished(parent, child_id, outcome) do
    CodingAgent.Core.Events.publish(parent.id, {:subagent_finished, child_id, outcome})
  end

  # -- Housekeeping -----------------------------------------------------------

  # Ephemeral: the child never persists, but a start that crashed before
  # reaching init could leave a row; deleting is best-effort and safe.
  # The child process is stopped too (it ran once; keeping it idle under
  # the supervisor would leak a process per delegation).
  defp cleanup(child_id) do
    Session.stop(child_id)
    Session.Store.delete(child_id)
  end

  defp child_id(parent) do
    "subagent-#{parent.id}-#{System.unique_integer([:positive])}"
  end

  # -- Argument reading -------------------------------------------------------

  defp fetch_type(args) do
    case arg(args, "subagent_type") do
      type when is_binary(type) and type != "" -> {:ok, type}
      _ -> {:error, "`subagent_type` is required"}
    end
  end

  defp arg(args, key) when is_map(args), do: Map.get(args, key) || Map.get(args, safe_atom(key))
  defp arg(_args, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__missing__
  end
end
