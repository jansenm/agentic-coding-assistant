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
  """

  use GenServer

  require Logger

  alias CodingAgent.Core.Compaction
  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.UserConfig
  alias CodingAgent.Core.Session.State
  alias CodingAgent.Core.Session.Store
  alias ReqLLM.Context

  # GenServer call timeout. Gate decisions can take arbitrarily long
  # (the user is a human reading the approval prompt), so decide/2 and
  # friends use :infinity. The LLM call inside a turn is bounded by the
  # provider's own timeouts, not this one.
  @call_timeout :infinity

  # live report: a real multi-step task burned 16 gate rounds and the
  # turn died with "tool loop limit reached: 12" — the agent then
  # complained about "flaky parallel calls". 12 was a phase-2 guess;
  # real coding tasks need more. 25 with the fail-closed behavior kept.
  @max_tool_rounds 25

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
    model = Keyword.get(opts, :model) || CodingAgent.model()
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
    {to_run, rejected} =
      Enum.reduce(pending, {[], []}, fn call, {run, res} ->
        {id, name, _args} = call_parts(call)
        decision = Map.fetch!(by_id, id)

        case decision do
          :approve ->
            {[call | run], res}

          {:edit, new_args} ->
            {[edit_call(call, new_args) | run], res}

          :reject ->
            {run, [%{id: id, name: name, content: "error: the user rejected this action"} | res]}
        end
      end)

    to_run = Enum.reverse(to_run)

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
    assistant_msg = assistant_message_for(pending)
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
        {id, name, _args} = call_parts(call)
        %ReqLLM.ToolCall{id: id, type: "function", function: %{name: name, arguments: "{}"}}
      end)

    %ReqLLM.Message{role: :assistant, content: [], tool_calls: tcalls}
  end

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

    state = %{state | context: context, status: :running, last_error: nil}
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

    state = maybe_compact(state)

    case call_llm(state) do
      {:ok, %{type: :final_answer, text: text, usage: usage}} ->
        state = state |> add_usage(usage) |> complete_turn(text)
        {state, {:ok, state}}

      {:ok, %{type: :tool_calls, tool_calls: calls, usage: usage}} ->
        state = add_usage(state, usage)
        gate_tools(state, calls)

      {:error, reason} ->
        Logger.error("LLM call failed: #{inspect(reason)}")
        state = fail_turn(state, reason)
        {state, {:error, reason}}
    end
  end

  # The permission checkpoint (ADR 010): read-only tools pass by policy
  # (allow class defaults); state-changing tools get the effective
  # decision. :ask pauses the session (:interrupted) until the driver
  # supplies decisions for every pending call via decide/3.
  defp gate_tools(state, calls) do
    if state.tool_rounds >= @max_tool_rounds do
      Logger.error("tool loop limit reached: #{@max_tool_rounds}")
      state = fail_turn(state, {:tool_loop_limit, @max_tool_rounds})
      {state, {:error, {:tool_loop_limit, @max_tool_rounds}}}
    else
      state = %{state | tool_rounds: state.tool_rounds + 1}

      {auto, pending} =
        Enum.split_with(calls, fn call ->
          {id, name, args} = call_parts(call)

          decision =
            Permissions.effective(
              state.policy,
              tool_name(name),
              call_rel_path(state, args),
              "default"
            )

          decisions_log(state, id, decision)
          decision == :allow
        end)

      cond do
        auto != [] and pending == [] ->
          run_tools(state, calls)

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
          # all denied: report rejections to the model instead of executing
          results = Enum.map(calls, fn call -> denied_result(call) end)
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

    Enum.map(calls, fn call ->
      {id, name, args} = call_parts(call)
      executing = %{id: id, name: name}

      case Enum.find(tools, &(&1.name == name)) do
        nil ->
          Map.put(executing, :content, "error: unknown tool #{name}")

        tool ->
          case ReqLLM.Tool.execute(tool, args) do
            {:ok, output} -> Map.put(executing, :content, to_text(output))
            {:error, msg} -> Map.put(executing, :content, "error: #{to_text(msg)}")
          end
      end
    end)
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
    with {:ok, base_opts} <- request_opts(state) do
      opts = Keyword.put(base_opts, :tools, current_tools(state))

      with {:ok, stream_response} <- ReqLLM.stream_text(state.model, state.context, opts) do
        events = ReqLLM.StreamResponse.events(stream_response)

        # consume_stream throws {:stream_error, ...} on stream failures
        # (e.g. provider down). Catch it HERE: a transport error is a
        # failed turn, never a session crash (the GenServer used to
        # terminate on this path — found in the 4a live smoke test).
        try do
          {text, tool_calls} = consume_stream(events, state.id)

          # real token accounting (sidebar, token-based compaction):
          # the metadata task resolves after the stream is fully consumed
          usage = ReqLLM.StreamResponse.usage(stream_response)
          {:ok, %{type: classify(tool_calls), text: text, tool_calls: tool_calls, usage: usage}}
        catch
          {:stream_error, error} -> {:error, {:stream_error, error}}
        end
      end
    end
  end

  # Credential resolution (ADR 014): env first, then the global
  # auth.toml. A provider with no credential connects keyless (local
  # ollama proxy); one with a credential sends it. base_url overrides
  # from auth.toml ride along (cloud-direct).
  defp request_opts(state) do
    provider = state.model |> String.split(":", parts: 2) |> List.first()

    case UserConfig.credential(provider) do
      {:ok, %{api_key: key}} ->
        {:ok, with_url(state, provider, api_key: key)}

      {:error, :none} ->
        {:ok, with_url(state, provider, [])}
    end
  end

  defp with_url(state, provider, opts) do
    case UserConfig.base_url(provider, state.provider_config || %{}) do
      nil -> opts
      url -> Keyword.put(opts, :base_url, url)
    end
  end

  @doc false
  def consume_stream(events, session_id) do
    events
    |> Enum.reduce({"", []}, fn
      %{type: :text_delta, data: delta}, {acc, calls} ->
        broadcast_text(session_id, delta)
        {acc <> delta, calls}

      %{type: :reasoning_delta, data: delta}, {acc, calls} ->
        broadcast_reasoning(session_id, delta)
        {acc, calls}

      %{type: :tool_call, data: call}, {acc, calls} ->
        {acc, [call | calls]}

      %{type: :error, data: error}, _acc ->
        throw({:stream_error, error})

      _event, acc ->
        acc
    end)
    |> then(fn {text, calls} -> {text, Enum.reverse(calls)} end)
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

    next = %{
      input_tokens: Map.get(prev, :input_tokens, 0) + (usage[:input_tokens] || 0),
      output_tokens: Map.get(prev, :output_tokens, 0) + (usage[:output_tokens] || 0),
      # the LAST turn's input = the context size the provider actually
      # saw — the honest token-based compaction measure (a chars-based
      # estimate drifts; the provider's own count is ground truth)
      last_input_tokens: usage[:input_tokens] || 0,
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

  # approaching the trigger (80%+): warn ONCE so compaction is never
  # a silent surprise (the opencode lesson: users trained on 'it will
  # auto compact' stop watching and then burn quota)
  @doc "Warns once at 80% of the compaction trigger. Public: tests are LLM-free."
  def warn_approaching_compaction(%State{} = state, trigger) do
    last_in = Map.get(state.usage || %{}, :last_input_tokens, 0)
    warn_at = trunc(trigger * 0.8)

    if last_in >= warn_at and not state.compaction_warned do
      state = %{state | compaction_warned: true}

      broadcast(
        state,
        {:info,
         "· context at #{div(last_in, 1000)}k tokens — compaction at #{div(trigger, 1000)}k will summarize older messages"}
      )

      persist(state)
      state
    else
      state
    end
  end

  defp fail_turn(state, reason) do
    state = %{state | status: :error, last_error: reason}
    broadcast(state, {:status_changed, :error, reason})
    persist(state)
    state
  end

  # Slice 4b: compact the working context when it grows past the
  # threshold. The summary call uses the same model without tools. On
  # any failure, skip compaction — an oversized context degrades, it
  # does not error out. The compacted state persists immediately (the
  # next turn boundary would too, but a crash right after compaction
  # should not resurrect the fat context).
  defp maybe_compact(%State{} = state) do
    # absolute threshold from config — visible in the sidebar,
    # predictable (the opencode lesson: compaction must be a known
    # quantity, not a silent %-of-window surprise)
    trigger =
      Application.get_env(
        :coding_agent,
        :compaction_trigger_tokens,
        Compaction.default_trigger_tokens()
      )

    last_in = Map.get(state.usage || %{}, :last_input_tokens, 0)

    plan =
      if last_in >= trigger do
        Compaction.plan_tokens(state.context, last_in, trigger)
      else
        Compaction.plan(state.context)
      end

    case plan do
      :none ->
        warn_approaching_compaction(state, trigger)

      {:ok, _old, _keep} ->
        Logger.debug(
          "compacting context (#{Compaction.total_chars(state.context.messages)} chars)"
        )

        case summarize_for_compaction(state) do
          {:ok, summary_text} ->
            context = Compaction.apply(state.context, summary_text)
            state = %{state | context: context}
            persist(state)
            broadcast(state, {:context_compacted, Compaction.keep_recent()})
            state

          {:error, reason} ->
            Logger.warning("compaction failed, keeping full context: #{inspect(reason)}")
            state
        end
    end
  end

  # The summarizer sees the OLD span only (the keep span is excluded —
  # the model would otherwise copy it into the summary).
  defp summarize_for_compaction(state) do
    {:ok, old, _keep} = Compaction.plan(state.context)

    context =
      Context.new()
      |> Context.append(
        ReqLLM.Context.system(
          "Summarize the following (possibly interrupted) coding-agent " <>
            "conversation for later reuse. Preserve: the user's goals, " <>
            "decisions made, files touched, commands run and their " <>
            "outcomes, and anything explicitly promised. Be factual and " <>
            "complete; omit small talk."
        )
      )
      |> Context.append(ReqLLM.Context.user(render_messages(old)))

    with {:ok, base_opts} <- request_opts(state),
         {:ok, response} <- ReqLLM.generate_text(state.model, context, base_opts) do
      {:ok, ReqLLM.Response.text(response)}
    end
  end

  defp render_messages(msgs) do
    Enum.map_join(msgs, "\n\n", fn
      %ReqLLM.Message{role: role, content: parts} when is_list(parts) ->
        text =
          Enum.map_join(parts, "", fn
            %ReqLLM.Message.ContentPart{text: t} when is_binary(t) -> t
            _ -> ""
          end)

        "[#{role}] #{text}"

      %ReqLLM.Message{role: role, content: c} when is_binary(c) ->
        "[#{role}] #{c}"

      _ ->
        ""
    end)
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
