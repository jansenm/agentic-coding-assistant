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

  alias CodingAgent.Core.Session.State
  alias ReqLLM.Context

  @call_timeout 120_000

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
  Subscribes the caller to session events (streaming deltas, status
  changes). Events arrive as `{:agent_event, event}` messages.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(id), do: GenServer.call(via(id), :subscribe)

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

  defp via(id), do: {:via, Registry, {CodingAgent.Registry, {:session, id}}}

  # -- Server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    model = Keyword.get(opts, :model)
    system_prompt = Keyword.get(opts, :system_prompt, @framework_prompt)

    context =
      Context.new()
      |> Context.append(ReqLLM.Context.system(system_prompt))

    {:ok, State.new(id: id, context: context, model: model, status: :idle)}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, {:ok, state}, state}

  def handle_call(:subscribe, {pid, _}, state) do
    unless pid == self(), do: Registry.register(CodingAgent.EventRegistry, {:session_events, state.id}, nil)
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
    case call_llm(state) do
      {:ok, %{type: :final_answer, text: text}} ->
        state = complete_turn(state, text)
        {state, {:ok, state}}

      {:ok, %{type: :tool_calls, tool_calls: calls}} ->
        state = %{state | status: :interrupted, pending_tool_calls: calls}
        broadcast(state, {:status_changed, :interrupted, calls})
        {state, {:ok, state}}

      {:error, reason} ->
        Logger.error("LLM call failed: #{inspect(reason)}")
        state = fail_turn(state, reason)
        {state, {:error, reason}}
    end
  end

  defp call_llm(state) do
    with {:ok, api_key} <- fetch_api_key(),
         {:ok, stream_response} <-
           ReqLLM.stream_text(state.model, state.context, api_key: api_key) do
      events = ReqLLM.StreamResponse.events(stream_response)
      {text, tool_calls} = consume_stream(events, state.id)
      {:ok, %{type: classify(tool_calls), text: text, tool_calls: tool_calls}}
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
        broadcast_text(session_id, delta)
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

  defp complete_turn(state, text) do
    context =
      state.context
      |> Context.append(ReqLLM.Context.assistant(text))

    state = %{state | context: context, status: :idle}
    broadcast(state, {:llm_message, text})
    broadcast(state, {:status_changed, :idle})
    state
  end

  defp fail_turn(state, reason) do
    state = %{state | status: :error, last_error: reason}
    broadcast(state, {:status_changed, :error, reason})
    state
  end

  # -- Infrastructure ---------------------------------------------------------

  defp fetch_api_key do
    env_var = Application.fetch_env!(:coding_agent, :api_key_env)

    case System.fetch_env(env_var) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, {:missing_api_key, env_var}}
    end
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