defmodule CodingAgent.Core.Session do
  @moduledoc """
  One agent session: an OTP process owning one conversation.

  Implements the agent loop from `docs/source/explanation/agent-loop.rst`.
  Phase 1 slice: prompt in, streamed LLM response out; tool calls are
  detected but the tool subsystem (phase 2) is not wired yet, so a
  tool-call turn surfaces as `{:tool_calls_requested, calls, state}` to
  the caller instead of being executed.

  The session state is plain data (ADR 003: everything is data so
  persistence and interruption become states, not exceptions).

  Separation of concerns within `CodingAgent.Core.Session.*`:

  - this module — the loop: turn lifecycle, tool gating, interrupts,
    event broadcast;
  - `CodingAgent.Core.Session.Compactor` — the compaction operation
    (trigger decision, summarize call, backoff);
  - `CodingAgent.Core.Session.Request` — wire-request assembly
    (model spec, providers, credentials) shared by every LLM call site;
  - `CodingAgent.Core.Session.Store` — persistence.
  """

  use GenServer

  require Logger

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Tools.Shell
  alias CodingAgent.Core.UserConfig
  alias CodingAgent.Core.Interrupt
  alias CodingAgent.Core.Session.{Compactor, Request, State, Store}
  alias ReqLLM.Context

  # GenServer call timeout. Gate decisions can take arbitrarily long
  # (the user is a human reading the approval prompt), so decide/2 and
  # friends use :infinity. The LLM call inside a turn is bounded by the
  # provider's own timeouts, not this one.
  @call_timeout :infinity

  # live report: a real multi-step task burned 16 gate rounds and the
  # turn died with "tool loop limit reached: 12" — the agent then
  # complained about "flaky parallel calls". 12 was a phase-2 guess;
  # GLM does one small grep per round: a review turn burned 25 rounds
  # live (7ce59be made the counter per-turn, but 25 still dies on a
  # legit review). Default now 100, configurable via
  # :max_tool_rounds — the guard exists to catch a runaway loop, and
  # its cost is proportional to the work actually requested.
  @default_max_tool_rounds 100

  defp max_tool_rounds do
    Application.get_env(:coding_agent, :max_tool_rounds, @default_max_tool_rounds)
  end

  # providers whose requests need no api_key option

  @framework_prompt """
  You are a coding assistant embedded in a terminal tool. Be concise and
  precise. When you intend to use a tool, emit the tool call; do not
  narrate that you are about to call tools.
  """

  # -- Client API -------------------------------------------------------------

  @doc "Starts a session process as part of the supervision tree."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Returns the session's current state (messages, status)."
  @spec state(String.t()) :: State.t() | {:error, :not_found}
  def state(id), do: GenServer.call(via(id), :state)

  @doc """
  Updates the LIVE session's in-memory id after a Store rename so its
  next save lands under the new name (no stale-file resurrection).
  The registry keeps the old key — the process remains addressable
  under the id it was started with until it exits; future mounts go
  through the renamed file.
  """
  def set_id(id, new_id) do
    GenServer.call(via(id), {:set_id, new_id})
  end

  @doc "Model-menu switch: swap the wire model for the NEXT turn."
  def set_model(id, model) do
    GenServer.call(via(id), {:set_model, model})
  end

  @doc """
  Subscribes the CALLER to session events (streaming deltas, status
  changes). Events arrive as `{:agent, event}` messages.

  Registry registration is process-local, so it must happen in the
  caller — the historical :subscribe call registered the *session*
  process instead (bug found by the TUI in 5a: the first real event
  consumer; the CLI never noticed because run/2 returns the final
  state and the deltas path was silently empty).
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(id) do
    _ = Registry.register(CodingAgent.EventRegistry, {:session_events, id}, nil)
    GenServer.call(via(id), :subscribe)
  end

  @doc """
  Runs one turn: sends the user prompt to the model and streams the
  answer to subscribers. Synchronous; returns the resulting state.
  """
  @spec run(String.t(), String.t()) :: {:ok, State.t()} | {:error, term()}
  def run(id, prompt), do: GenServer.call(via(id), {:run, prompt}, @call_timeout)

  @doc """
  Interrupts a running turn (user stop request, opencode's esc).

  Delegates to `CodingAgent.Core.Interrupt`, which owns the flag and the
  active stream's cancel handle. This is a thin convenience so callers
  (the TUI) don't need to know the coordinator module.
  """
  @spec interrupt(String.t()) :: :ok
  defdelegate interrupt(id), to: CodingAgent.Core.Interrupt, as: :request

  @doc """
  Finishes a turn after phase-2 tool executions; phase 1 uses this to
  continue the loop after a human provides or performs a tool result.
  """
  @spec submit_tool_results(String.t(), [map()]) ::
          {:ok, State.t()} | {:error, term()}
  def submit_tool_results(id, results),
    do: GenServer.call(via(id), {:tool_results, results}, @call_timeout)

  @doc """
  Supplies decisions for pending tool calls (ADR 010: approve / edit /
  reject, one decision per call) and resumes the interrupted turn.
  """
  @spec decide(String.t(), [%{id: String.t(), decision: :approve | :reject | {:edit, map()}}]) ::
          {:ok, State.t()} | {:error, term()}
  def decide(id, decisions), do: GenServer.call(via(id), {:decide, decisions}, @call_timeout)

  @doc """
  Feeds tool calls directly into the permission gate, bypassing the
  LLM. Test-only hook (phase-2 test support); not part of the public
  driver contract.
  """
  @doc since: "0.1.0"
  @spec debug_gate(String.t(), [map()]) :: :ok | {:error, term()}
  def debug_gate(id, calls) when is_list(calls) do
    GenServer.call(via(id), {:debug_gate, calls}, @call_timeout)
  end

  defp via(id), do: {:via, Registry, {CodingAgent.Registry, {:session, id}}}

  # -- Server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    # no model in code (user decision): a fresh session needs the
    # configured default; nil fails loudly here (the TUI guard usually
    # catches this first)
    model =
      Keyword.get(opts, :model) ||
        CodingAgent.model() ||
        raise(
          "no model configured — set model = \"provider:model\" in " <>
            CodingAgent.Core.UserConfig.global_dir() <> "/config.toml"
        )

    system_prompt = Keyword.get(opts, :system_prompt, @framework_prompt)
    scope_root = Keyword.get(opts, :scope_root)
    test_mode = Keyword.get(opts, :test_mode, false)
    policy = Keyword.get(opts, :policy) || load_policy(scope_root)

    # Project memory (4c): AGENTS.md at the scope root is read once at
    # session start and appended to the system prompt — the long-term
    # memory tier that writes knowledge down as files (memory.rst).
    # Missing file is the normal case; unreadable/corrupt content
    # degrades to a warning, never an error.
    system_prompt = append_project_memory(system_prompt, scope_root)

    # Resume support (4a): a caller may pass a persisted :context (and
    # then model/policy come from the snapshot too); otherwise a fresh
    # context with the framework system prompt is created.
    context =
      case Keyword.get(opts, :context) do
        nil ->
          Context.new()
          |> Context.append(ReqLLM.Context.system(system_prompt))

        %Context{} = restored ->
          restored
      end

    {:ok,
     State.new(
       id: id,
       context: context,
       model: model,
       status: :idle,
       scope_root: scope_root,
       policy: policy,
       # [providers.*] snapshot (layer 0 < global < project): consulted
       # per request (request_parts/1) and by the TUI's model menu
       # (provider_config_of/1). Found live NEVER SEEDED — every
       # session resolved against an empty registry, so non-native
       # providers (ollama_cloud via provider = "openai") failed closed
       # with :bad_entry and the model menu showed only the current
       # model.
       provider_config: UserConfig.load(scope_root).config["providers"] || %{},
       test_mode: test_mode
     )}
  end

  # AGENTS.md at the scope root: project conventions for the agent
  # (the pragmatic long-term memory: knowledge written down as files,
  # pulled back by this loader instead of exotic memory systems).
  @agents_file "AGENTS.md"
  @agents_max_bytes 64 * 1024

  defp append_project_memory(prompt, scope_root) do
    file = scope_root && Path.join(scope_root, @agents_file)

    cond do
      not is_binary(file) ->
        prompt

      not File.regular?(file) ->
        prompt

      true ->
        case File.read(file) do
          {:ok, bytes} when byte_size(bytes) <= @agents_max_bytes ->
            prompt <> "\n\n" <> project_memory_section(bytes)

          {:ok, bytes} when byte_size(bytes) > @agents_max_bytes ->
            Logger.warning("AGENTS.md larger than 64 KiB; truncated for the system prompt")

            prompt <> "\n\n" <> project_memory_section(binary_part(bytes, 0, @agents_max_bytes))

          {:error, reason} ->
            Logger.warning("AGENTS.md unreadable: #{inspect(reason)}")
            prompt
        end
    end
  end

  defp project_memory_section(text) do
    """
    # Project memory (AGENTS.md)

    Conventions and context for THIS project, written by the team:

    #{String.trim_trailing(text)}
    """
  end

  # Policy loading at session start (ADR 010: no live reload). The
  # repo-side file lives at the scope root; the user-side path comes
  # from config. Fail-closed is inherited from the Permissions loader.
  defp load_policy(scope_root) do
    # ADR 014: the user layer is ~/.config/coding-agent/permissions.toml,
    # the project layer .coding-agent/permissions.toml (legacy
    # agent-permissions.toml still read for the transition)
    CodingAgent.Core.UserConfig.load(scope_root).permissions
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, {:ok, state}, state}

  def handle_call({:set_id, new_id}, _from, state) do
    {:reply, :ok, struct!(state, id: new_id)}
  end

  # model-menu switch: swap the wire model mid-session. The NEXT turn
  # resolves it (request_parts/1 splits state.model per call), so a
  # running session changes models at the boundary, not mid-stream.
  def handle_call({:set_model, model}, _from, state) do
    {:reply, :ok, struct!(state, model: model)}
  end

  def handle_call(:subscribe, {pid, _}, state) do
    # registry registration happened in the caller (see subscribe/1);
    # the monitor lets the session drop dead subscribers
    monitor = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [monitor | state.subscribers]}}
  end

  def handle_call({:run, prompt}, _from, state) do
    {state, result} = run_turn(prompt, state)
    {:reply, result, state}
  end

  def handle_call({:tool_results, results}, _from, state) do
    state = append_tool_results(state, results)
    {state, result} = continue_loop(state)
    {:reply, result, state}
  end

  def handle_call({:debug_gate, calls}, _from, state) do
    state = %{state | status: :running, tool_rounds: 0, test_mode: true}
    {state, _result} = gate_tools(state, calls)
    {:reply, :ok, state}
  end

  # ADR 010: driver decisions for interrupted (pending) tool calls.
  # decisions: list of maps %{id: call-id, decision: :approve | {:edit, args} | :reject}
  # The turn resumes only when every pending call has a decision.
  def handle_call({:decide, decisions}, _from, %{status: :interrupted} = state) do
    pending = state.pending_tool_calls
    by_id = Map.new(decisions, fn d -> {d.id, d.decision} end)

    missing =
      Enum.reject(pending, fn call ->
        {id, _, _} = call_parts(call)
        Map.has_key?(by_id, id)
      end)

    if missing != [] do
      {:reply,
       {:error, {:missing_decisions, Enum.map(missing, fn c -> elem(call_parts(c), 0) end)}},
       state}
    else
      state = resolve_decisions(state, pending, by_id)

      if state.test_mode do
        # gate-mechanics tests stop here: no LLM round-trip
        state = %{state | status: :idle}
        persist(state)
        {:reply, {:ok, state}, state}
      else
        {state, result} = continue_loop(state)
        {:reply, result, state}
      end
    end
  end

  def handle_call({:decide, _decisions}, _from, state) do
    {:reply, {:error, {:not_interrupted, state.status}}, state}
  end

  # Apply approve/edit/reject to every pending call; build tool-result
  # messages so the model sees the outcome. Approved/edited calls are
  # executed immediately; rejected calls get a rejection message.
  defp resolve_decisions(state, pending, by_id) do
    {to_run, rejected, final_calls} =
      Enum.reduce(pending, {[], [], []}, fn call, {run, res, finals} ->
        {id, name, _args} = call_parts(call)
        decision = Map.fetch!(by_id, id)

        case decision do
          :approve ->
            {[call | run], res, [call | finals]}

          {:edit, new_args} ->
            edited = edit_call(call, new_args)
            {[edited | run], res, [edited | finals]}

          :reject ->
            {run, [%{id: id, name: name, content: "error: the user rejected this action"} | res],
             [call | finals]}
        end
      end)

    to_run = Enum.reverse(to_run)
    final_calls = Enum.reverse(final_calls)

    executed_results = execute_tools(state, to_run)

    Enum.each(executed_results, fn r ->
      broadcast(state, {:tool_executed, r.name, r.content})
    end)

    all_results =
      Enum.map(rejected ++ executed_results, fn r ->
        %ReqLLM.Message{
          role: :tool,
          name: r.name,
          tool_call_id: r.id,
          content: [ReqLLM.Message.ContentPart.text(r.content)]
        }
      end)

    # the canonical exchange validates id matching and appends the
    # assistant tool-call message with every result in order
    assistant_msg = assistant_message_for(final_calls)
    exchange = ReqLLM.Context.append_tool_exchange(state.context, assistant_msg, all_results)

    case exchange do
      {:ok, context} ->
        state = %{state | pending_tool_calls: [], context: context}
        persist(state)
        state

      {:error, reason} ->
        Logger.error("tool exchange failed: #{inspect(reason)}")
        state
    end
  end

  defp assistant_message_for(calls) do
    tcalls =
      Enum.map(calls, fn call ->
        {id, name, args} = call_parts(call)

        %ReqLLM.ToolCall{
          id: id,
          type: "function",
          function: %{name: name, arguments: args_json(args)}
        }
      end)

    %ReqLLM.Message{role: :assistant, content: [], tool_calls: tcalls}
  end

  # The assistant tool-call message goes back to the model, so it must
  # carry the args the model produced (or the user edited in). A
  # hardcoded "{}" here erased every prior call's arguments from the
  # model's view — the model then saw its own shell calls as empty and
  # re-emitted empty-args calls (live: 12-round loop of
  # "required :command option not found" — the "dropped command" bug).
  defp args_json(args) when is_binary(args), do: args
  defp args_json(args) when is_map(args), do: Jason.encode!(args)
  defp args_json(_args), do: "{}"

  defp edit_call(%ReqLLM.ToolCall{} = call, new_args) do
    %{call | function: %{call.function | arguments: Jason.encode!(new_args)}}
  end

  defp edit_call(%{arguments: _} = call, new_args), do: %{call | arguments: new_args}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, monitor)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- The loop ---------------------------------------------------------------

  defp run_turn(prompt, state) do
    context =
      state.context
      |> Context.append(ReqLLM.Context.user(prompt))

    # the loop guard is PER TURN: the counter previously only reset in
    # the debug path, so it accumulated across a session's lifetime —
    # found live: the review session died at the 25-round limit after
    # several healthy turns (each turn's rounds stack on the old count)
    state = %{state | context: context, status: :running, last_error: nil, tool_rounds: 0}
    broadcast(state, {:status_changed, :running})

    case continue_loop(state) do
      {state, result} -> {state, result}
    end
  end

  defp continue_loop(state) do
    # structural backstop for the tests-are-LLM-free discipline: a
    # test-mode session must never reach the provider, no matter what
    # code path leads here. Loud on purpose — a silent skip would let
    # a regression hide.
    if state.test_mode do
      raise "test-mode session #{state.id} reached call_llm — tests must be LLM-free"
    end

    # Loop boundary: a stop requested during an uninterruptible step
    # (compaction summarize, a long tool round) is honored here before
    # another provider call starts. There is no streamed text at this
    # point — end the turn idle (no empty assistant message on the wire)
    # and tell the transcript why.
    if Interrupt.requested?(state.id) do
      state = state |> drop_interrupt() |> stop_at_boundary()
      {state, {:ok, state}}
    else
      {state, changed?} = Compactor.maybe_compact(state)
      if changed?, do: persist(state)

      case call_llm(state) do
        {:ok, %{type: :final_answer, text: text, usage: usage}} ->
          state = state |> add_usage(usage) |> drop_interrupt() |> complete_turn(text)
          {state, {:ok, state}}

        {:ok, %{type: :tool_calls, tool_calls: calls, usage: usage}} ->
          state = state |> add_usage(usage) |> drop_interrupt()
          gate_tools(state, calls)

        # user stop (Interrupt.request/1): the partial text streamed so
        # far becomes the turn's answer (opencode esc parity — nothing
        # lost, the model can be nudged on from there)
        {:interrupted, partial} ->
          state = state |> drop_interrupt() |> complete_turn(partial)
          {state, {:ok, state}}

        {:error, reason} ->
          state = state |> drop_interrupt() |> fail_turn(reason)
          {state, {:error, reason}}
      end
    end
  end

  # Turn end for a boundary stop: no streamed text exists, so there is
  # nothing to keep — just go idle and surface a transcript note.
  defp stop_at_boundary(state) do
    state = %{state | status: :idle}
    broadcast(state, {:info, "· turn stopped (esc)"})
    broadcast(state, {:status_changed, :idle})
    persist(state)
    state
  end

  # The permission checkpoint (ADR 010): read-only tools pass by policy
  # (allow class defaults); state-changing tools get the effective
  # decision. :ask pauses the session (:interrupted) until the driver
  # supplies decisions for every pending call via decide/3.
  defp gate_tools(state, calls) do
    if state.tool_rounds >= max_tool_rounds() do
      Logger.error("tool loop limit reached: #{max_tool_rounds()}")

      # tell the user IN the transcript (a bare error turn is a
      # mystery — the user then asks 'what stopped it now?')
      broadcast(
        state,
        {:info,
         "· turn stopped: #{max_tool_rounds()} tool rounds used (the per-turn guard) — ask it to continue for another budget"}
      )

      state = fail_turn(state, {:tool_loop_limit, max_tool_rounds()})
      {state, {:error, {:tool_loop_limit, max_tool_rounds()}}}
    else
      state = %{state | tool_rounds: state.tool_rounds + 1}

      # Command blacklist (2026-09-15 amendment 2, BEFORE the policy
      # lookup): a shell call whose leading program duplicates a native
      # tool is denied with a steering message — no keystroke for the
      # user, and the model gets the better-tool hint as its tool
      # result in the same round. append_tool_results here (not in the
      # predicate) so the context update happens exactly once per call.
      {denied, rest} =
        Enum.split_with(calls, fn call ->
          {_id, name, args} = call_parts(call)
          name == "shell" and match?({:ok, _}, Shell.blacklisted?(args))
        end)

      state =
        case denied do
          [] ->
            state

          denied ->
            results =
              Enum.map(denied, fn call ->
                {id, _name, args} = call_parts(call)
                {:ok, guidance} = Shell.blacklisted?(args)
                Logger.warning("gate: shell command denied (blacklist): #{inspect(id)}")
                decisions_log(state, id, :deny)
                %{id: id, name: "shell", content: "error: #{guidance}"}
              end)

            state = append_tool_results(state, results)

            Enum.each(results, fn r ->
              broadcast(state, {:tool_executed, "shell", r.content})
            end)

            persist(state)
            state
        end

      {auto, pending} =
        Enum.split_with(rest, fn call ->
          {_id, name, args} = call_parts(call)

          decision =
            Permissions.effective(
              state.policy,
              tool_name(name),
              call_rel_path(state, args),
              "default"
            )

          {id, _, _} = call_parts(call)
          decisions_log(state, id, decision)
          decision == :allow
        end)

      cond do
        auto != [] and pending == [] ->
          run_tools(state, rest)

        auto != [] ->
          # mixed: execute allowed ones now, park the rest
          execute_and_continue(state, auto, pending)

        pending != [] ->
          state = %{
            state
            | status: :interrupted,
              pending_tool_calls: pending
          }

          broadcast(state, {:status_changed, :interrupted, pending})
          persist(state)
          {state, {:ok, state}}

        true ->
          # all (remaining) denied: report rejections to the model instead
          # of executing — `rest`, blacklisted calls were already answered
          results = Enum.map(rest, fn call -> denied_result(call) end)
          state = append_tool_results(state, results)

          if state.test_mode do
            {state, {:ok, state}}
          else
            continue_loop(state)
          end
      end
    end
  end

  # Auto-executed calls, then continue with the pending ones parked.
  defp execute_and_continue(state, auto, pending) do
    auto_results = execute_tools(state, auto)
    state = %{state | pending_tool_calls: pending, status: :interrupted}
    state = %{state | context: append_tool_results(state, auto_results).context}
    broadcast_tools(state, auto, auto_results)
    broadcast(state, {:status_changed, :interrupted, pending})
    persist(state)
    {state, {:ok, state}}
  end

  defp run_tools(state, calls) do
    results = execute_tools(state, calls)
    state = append_tool_results(state, results)
    broadcast_tools(state, calls, results)

    if state.test_mode do
      {state, {:ok, state}}
    else
      continue_loop(state)
    end
  end

  defp denied_result(call) do
    {id, name, _} = call_parts(call)

    %{
      id: id,
      name: name,
      content: "error: permission denied by policy; the user did not approve this action"
    }
  end

  defp decisions_log(_state, _id, :allow), do: :ok

  defp decisions_log(state, id, decision) do
    Logger.debug("gate: tool call #{inspect(id)} in session #{state.id} -> #{decision}")
  end

  defp tool_name(name) when is_binary(name), do: name
  defp tool_name(other), do: to_string(other)

  # The policy matches against the tool's path argument, relative to the
  # scope root. The gate consults the call's OWN arguments — this is the
  # security boundary, so the path always comes from the call itself.
  defp call_rel_path(state, args) when is_map(args) do
    path = Map.get(args, "path") || Map.get(args, :path)

    case path do
      p when is_binary(p) ->
        root = Path.expand(state.scope_root || File.cwd!())
        expanded = Path.expand(p, root)

        if String.starts_with?(expanded <> "/", root <> "/") do
          Path.relative_to(expanded, root)
        else
          # absolute path outside scope: policy matches the raw path; the
          # tool itself will reject execution anyway
          p
        end

      _ ->
        ""
    end
  end

  defp call_rel_path(_state, _args), do: ""

  defp execute_tools(state, calls) do
    tools = current_tools(state)

    # A stop requested between sequential tool executions of one round is
    # honored here: already-run tools keep their real result, everything
    # after the stop gets a synthetic result (the exchange still needs
    # one result per tool call to stay valid on the wire). Mid-tool
    # cancellation (a running shell) is deliberately out of scope — see
    # CodingAgent.Core.Interrupt.
    {results, _stopped?} =
      Enum.reduce(calls, {[], false}, fn call, {acc, stopped?} ->
        {id, name, args} = call_parts(call)
        executing = %{id: id, name: name}

        cond do
          stopped? or Interrupt.requested?(state.id) ->
            {[Map.put(executing, :content, "error: stopped by the user") | acc], true}

          true ->
            {[run_one_tool(executing, name, args, tools) | acc], false}
        end
      end)

    Enum.reverse(results)
  end

  defp run_one_tool(executing, name, args, tools) do
    case Enum.find(tools, &(&1.name == name)) do
      nil ->
        # list the valid names: the model can self-correct in one round
        # (found live: GLM emitted tool calls named "assistant" —
        # provider-side mislabeling; with the names in the error it
        # retries with the right tool instead of spiraling)
        names = tools |> Enum.map(& &1.name) |> Enum.sort()

        Map.put(
          executing,
          :content,
          "error: unknown tool #{inspect(name)} — available tools: #{Enum.join(names, ", ")}"
        )

      tool ->
        case ReqLLM.Tool.execute(tool, args) do
          {:ok, output} -> Map.put(executing, :content, to_text(output))
          {:error, msg} -> Map.put(executing, :content, "error: #{to_text(msg)}")
        end
    end
  end

  # Tool calls arrive in two shapes: as ReqLLM.ToolCall structs
  # (function: %{name, arguments}) or as plain maps from stream events
  # (name/arguments at top level).
  defp call_parts(%ReqLLM.ToolCall{id: id, function: %{name: name, arguments: args}}),
    do: {id, name, ensure_args(args)}

  defp call_parts(%{id: id, name: name, arguments: args}) when is_map(args),
    do: {id, name, args}

  defp call_parts(%{id: id, name: name}), do: {id, name, %{}}

  defp ensure_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp ensure_args(args) when is_map(args), do: args
  defp ensure_args(_), do: %{}

  defp broadcast_tools(state, calls, results) do
    by_id = Map.new(results, &{&1.id, &1.content})

    Enum.each(calls, fn call ->
      {id, name, _args} = call_parts(call)
      content = Map.get(by_id, id, "")
      broadcast(state, {:tool_executed, name, content})
    end)
  end

  defp current_tools(state) do
    CodingAgent.Core.Tools.all(tool_scope(state))
  end

  defp tool_scope(state) do
    root = state.scope_root || File.cwd!()
    %{root: root}
  end

  defp to_text(output) when is_binary(output), do: output
  defp to_text(output), do: inspect(output, pretty: true, limit: 100)

  defp call_llm(state) do
    with {:ok, model_input, base_opts} <- Request.build(state.model, state.provider_config) do
      opts = Keyword.put(base_opts, :tools, current_tools(state))

      with {:ok, stream_response} <- ReqLLM.stream_text(model_input, state.context, opts) do
        events = ReqLLM.StreamResponse.events(stream_response)

        # Hand the active stream's hard-cancel to the interrupt
        # coordinator: a stop request then closes the underlying
        # ReqLLM.StreamResponse, which cancels the HTTP work and
        # releases the session's blocked `next` call — the only way to
        # stop a reasoning-only stream that never emits another delta.
        Interrupt.register(state.id, fn -> ReqLLM.StreamResponse.close(stream_response) end)

        # consume_stream throws {:stream_error, ...} on stream failures
        # and returns {:interrupted, text} when the user stops the turn.
        # Catch the throw HERE: a transport error is a failed turn, an
        # interrupt is a finished (partial) turn — neither may crash the
        # session (the GenServer used to terminate on this path — found
        # in the 4a live smoke test).
        try do
          case consume_stream(events, state.id) do
            {:interrupted, partial} ->
              {:interrupted, partial}

            {text, tool_calls} ->
              # real token accounting (sidebar, token-based compaction):
              # the metadata task resolves after the stream is fully consumed
              usage = ReqLLM.StreamResponse.usage(stream_response)

              {:ok,
               %{type: classify(tool_calls), text: text, tool_calls: tool_calls, usage: usage}}
          end
        catch
          {:stream_error, error} -> {:error, {:stream_error, error}}
        after
          Interrupt.unregister(state.id)
        end
      end
    end
  end

  @doc false
  def consume_stream(events, session_id) do
    partial_key = {__MODULE__, :partial, session_id}
    Process.put(partial_key, "")

    try do
      events
      |> Enum.reduce_while({:streaming, "", []}, fn event, acc ->
        event
        |> handle_event(acc, session_id, partial_key)
        |> interrupt_check(session_id)
      end)
      |> interrupt_result(session_id)
    catch
      # Narrow race: Interrupt fires StreamResponse.close from a spawned
      # process; if it lands between two events, the next
      # StreamServer.next call reaches the already-stopped server and
      # exits. If a stop was requested that is exactly the intended
      # outcome — return the partial text streamed so far instead of
      # letting the exit crash the session. Any other exit is a real
      # stream failure and is re-raised.
      :exit, reason ->
        if Interrupt.requested?(session_id) do
          {:interrupted, Process.get(partial_key, "")}
        else
          :erlang.raise(:exit, reason, __STACKTRACE__)
        end
    after
      Process.delete(partial_key)
    end
  end

  defp interrupt_result({:interrupted, text, _calls}, _session_id), do: {:interrupted, text}

  defp interrupt_result({:streaming, text, calls}, session_id) do
    # A hard cancel (Interrupt fires StreamResponse.close) empties the
    # provider queue and ends the stream with a plain `:halt` — no
    # further event reaches interrupt_check. Classify that as an
    # interrupt too, so the partial answer is kept instead of looking
    # like a clean finish.
    if Interrupt.requested?(session_id) do
      {:interrupted, text}
    else
      {text, Enum.reverse(calls)}
    end
  end

  # Broadcast the event's payload and fold it into the accumulator. The
  # flag check lives in interrupt_check/2 applied after EVERY event (not
  # per clause): a non-delta event after a hard cancel must also halt, or
  # the next pull would hit the already-stopped StreamServer and exit.
  defp handle_event(%{type: :text_delta, data: delta}, {:streaming, acc, calls}, session_id, key) do
    broadcast_text(session_id, delta)
    partial = acc <> delta
    Process.put(key, partial)
    {:streaming, partial, calls}
  end

  defp handle_event(
         %{type: :reasoning_delta, data: delta},
         {:streaming, acc, calls},
         session_id,
         key
       ) do
    broadcast_reasoning(session_id, delta)
    Process.put(key, acc)
    {:streaming, acc, calls}
  end

  defp handle_event(%{type: :tool_call, data: call}, {:streaming, acc, calls}, _session_id, _key) do
    {:streaming, acc, [call | calls]}
  end

  defp handle_event(%{type: :error, data: error}, _acc, _session_id, _key) do
    throw({:stream_error, error})
  end

  defp handle_event(_event, acc, _session_id, _key), do: acc

  # The user's stop request lands in the coordinator's ETS flag
  # (`Interrupt.request/1` cannot GenServer.call the session — it is busy
  # consuming this very stream). Checked after every stream event; stop
  # early keeping the partial text as the turn's answer (opencode esc
  # parity).
  defp interrupt_check({:streaming, acc, calls}, session_id) do
    if Interrupt.requested?(session_id) do
      {:halt, {:interrupted, acc, calls}}
    else
      {:cont, {:streaming, acc, calls}}
    end
  end

  defp classify([]), do: :final_answer
  defp classify(_calls), do: :tool_calls

  defp append_tool_results(state, results) do
    messages =
      Enum.map(results, fn %{id: id, name: name, content: content} ->
        Context.tool_result_message(name, id, content)
      end)

    %{state | context: Context.append(state.context, messages), pending_tool_calls: []}
  end

  # cumulative session usage: input+output per turn; cost only when
  # the provider prices it (ollama cloud: usage.cost may be nil)
  @doc """
  Accumulates one turn's provider usage into the session state
  (cumulative input/output, last turn's input as the compaction
  measure, cost when priced) and broadcasts {:usage_updated, usage}.
  Public for tests: the accounting is core behavior, and the tests
  are LLM-free so they exercise it directly.
  """
  def add_usage(state, usage) when is_map(usage) do
    prev = state.usage || %{input_tokens: 0, output_tokens: 0, cost: nil}

    # a nil/zero input count (interrupted or error turn, provider usage
    # event missing) must NOT clobber the honest count from the last
    # complete turn — a zero here silently re-arms the chars-based
    # compaction fallback on a fat context (found live: session
    # resumed, compaction fired at 212K chars despite the sidebar
    # showing 58.3k)
    last_in =
      case usage[:input_tokens] do
        n when is_integer(n) and n > 0 -> n
        _ -> Map.get(prev, :last_input_tokens, 0)
      end

    next = %{
      input_tokens: Map.get(prev, :input_tokens, 0) + (usage[:input_tokens] || 0),
      output_tokens: Map.get(prev, :output_tokens, 0) + (usage[:output_tokens] || 0),
      # the LAST turn's input = the context size the provider actually
      # saw — the honest token-based compaction measure (a chars-based
      # estimate drifts; the provider's own count is ground truth)
      last_input_tokens: last_in,
      cost: sum_cost(prev[:cost], usage[:total_cost])
    }

    state = %{state | usage: next}
    broadcast(state, {:usage_updated, next})
    state
  end

  def add_usage(state, nil), do: state

  defp sum_cost(nil, nil), do: nil
  defp sum_cost(a, b), do: (a || 0.0) + (b || 0.0)

  defp complete_turn(state, text) do
    context =
      state.context
      |> Context.append(ReqLLM.Context.assistant(text))

    state = %{state | context: context, status: :idle}
    broadcast(state, {:llm_message, text})
    broadcast(state, {:status_changed, :idle})
    persist(state)
    state
  end

  # Compaction is delegated to `CodingAgent.Core.Session.Compactor`
  # (trigger decision, summarize task, backoff); nothing of it lives
  # here — the loop only asks "should the context shrink?" and gets
  # {state, changed?} back.

  defp fail_turn(state, reason) do
    # the turn is over in every branch from here — drop any stale
    # user-interrupt flag so the NEXT turn starts clean
    drop_interrupt(state)
    state = %{state | status: :error, last_error: reason}
    broadcast(state, {:status_changed, :error, reason})
    persist(state)
    state
  end

  # turn-end cleanup: the stop flag is per-turn, never carries over
  defp drop_interrupt(state) do
    Interrupt.clear(state.id)
    state
  end

  # Slice 4a: every turn boundary leaves a persisted snapshot.  # Slice 4a: every turn boundary leaves a persisted snapshot. A crash
  # mid-turn loses at most the current turn — the previous boundary is
  # on disk. Failures are logged, never raised: an unwritable disk
  # must not kill a working session.
  defp persist(state) do
    case Store.save(state) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("session persist failed: #{inspect(reason)}")
    end

    state
  end

  # -- Infrastructure ---------------------------------------------------------

  defp broadcast_reasoning(session_id, delta) do
    Registry.dispatch(CodingAgent.EventRegistry, {:session_events, session_id}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:agent, {:reasoning_deltas, delta}})
    end)
  end

  defp broadcast_text(session_id, delta) do
    Registry.dispatch(CodingAgent.EventRegistry, {:session_events, session_id}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:agent, {:llm_deltas, delta}})
    end)
  end

  defp broadcast(state, event) do
    Registry.dispatch(CodingAgent.EventRegistry, {:session_events, state.id}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:agent, event})
    end)
  end
end
