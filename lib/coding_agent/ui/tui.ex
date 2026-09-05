defmodule CodingAgent.UI.Tui do
  @moduledoc """
  The phase-5 terminal UI driver (5a render foundation + 5b interaction).

  Layout: transcript pane (scrollable) / input area / status line.
  Input is an ExRatatui Textarea — enter inserts a newline (ADR 011
  composition-first default); alt-enter sends the buffer to the agent.
  The ADR 011 keymap is the action table; UI.Bridge translates
  terminal events; UI.Keymap resolves actions.

  Approval flow (ADR 010): when the gate interrupts, the pending calls
  render as a dialog; y approves, n rejects, e edits — per-key editing
  of single-line values in the dialog (multiline values shown
  read-only; the CLI limitation does not recur: paste is a terminal
  event here, and args render pretty-printed).
  """

  use ExRatatui.App

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.Supervisor
  alias CodingAgent.Core.Session.Store
  alias CodingAgent.UI.{Bridge, Keymap}
  alias ExRatatui.Event
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Paragraph, Textarea}

  @input_height 4

  @impl true
  def mount(opts) do
    id = Keyword.get(opts, :session_id) || "tui-#{System.unique_integer([:positive])}"
    prompt = Keyword.get(opts, :initial_prompt)

    with {:ok, _pid} <- start_session(id, opts) do
      Session.subscribe(id)

      # attach to the CURRENT state, not a stale idle assumption: the
      # session may already be running/interrupted (e.g. attached after
      # the gate paused, or resumed from disk)
      {status, pending} =
        case Session.state(id) do
          {:ok, st} -> {st.status, st.pending_tool_calls}
          _ -> {:idle, []}
        end

      initial = %{
        session_id: id,
        status: status,
        transcript: [],
        deltas: "",
        textarea: ExRatatui.textarea_new(),
        history: [],
        history_index: nil,
        pending: pending,
        pending_edit: nil,
        last_error: nil,
        test_pid: Keyword.get(opts, :test_pid)
      }

      if prompt, do: send(self(), {:__run__, prompt})

      {:ok, initial}
    end
  end

  defp start_session(id, opts) do
    persisted = Keyword.get(opts, :resume_id) && Store.load(Keyword.fetch!(opts, :resume_id))

    case persisted do
      {:ok, state} ->
        Supervisor.start_session(
          id: state.id,
          context: state.context,
          model: state.model,
          scope_root: state.scope_root,
          policy: state.policy
        )

      _ ->
        Supervisor.start_session(
          id: id,
          scope_root: Keyword.get(opts, :scope_root) || File.cwd!()
        )
    end
  end

  # -- Terminal events -------------------------------------------------------

  @impl true
  def handle_event(%Event.Key{kind: "press"} = ev, state) do
    # two-tier bridge (ADR 011 + the UTF-8 lesson): only special keys
    # and letters the keymap binds become keymap events; everything
    # else is text, forwarded raw to the textarea
    bound = Bridge.bound_letters(Keymap.defaults()) ++ Bridge.bound_letters(decision_keymap())

    case Bridge.translate(ev, bound) do
      {:text, code} ->
        {:noreply, put_in_textarea(state, code)}

      {:key, km_event} ->
        if state.pending != [] do
          handle_decision_key(km_event, state)
        else
          handle_input_key(km_event, ev, state)
        end
    end
  end

  def handle_event(%Event.Paste{content: text}, state) do
    state = put_in_textarea(state, text)
    {:noreply, state}
  end

  def handle_event(_event, state), do: {:noreply, state}

  # In the dialog: y/n/e decide; everything else ignored.
  defp handle_decision_key(km_event, state) do
    case Keymap.resolve(decision_keymap(), km_event) do
      :approve ->
        {:noreply, decide(state, :approve)}

      :reject ->
        {:noreply, decide(state, :reject)}

      :edit ->
        state =
          %{
            state
            | transcript:
                state.transcript ++
                  [{:info, "· arg editing arrives in 5c — use n (reject) for now"}]
          }

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp decision_keymap do
    %{
      approve: [%{key: :y, mod: :none}],
      reject: [%{key: :n, mod: :none}],
      edit: [%{key: :e, mod: :none}]
    }
  end

  # Input area keys: intercept actions BEFORE the textarea consumes them.
  defp handle_input_key(km_event, ev, state) do
    # empty-buffer q quits (kept from 5a); with text, q is just text
    if km_event == %{key: :q, mod: :none} and buffer_empty?(state) do
      {:stop, state}
    else
      dispatch_input_key(km_event, ev, state)
    end
  end

  defp buffer_empty?(state) do
    ExRatatui.textarea_get_value(state.textarea) == ""
  end

  defp dispatch_input_key(km_event, ev, state) do
    case Keymap.resolve(Keymap.defaults(), km_event) do
      :send_input ->
        {:noreply, send_input(state)}

      :insert_newline ->
        forward_to_textarea(state, ev)

      :history_prev ->
        {:noreply, history_step(state, +1)}

      :history_next ->
        {:noreply, history_step(state, -1)}

      :abort ->
        {:stop, state}

      _ ->
        forward_to_textarea(state, ev)
    end
  end

  defp send_input(state) do
    value = String.trim(ExRatatui.textarea_get_value(state.textarea))

    if value == "" do
      state
    else
      Task.start(fn -> Session.run(state.session_id, value) end)

      %{
        state
        | textarea: ExRatatui.textarea_new(),
          history: [value | state.history],
          history_index: nil,
          transcript: state.transcript ++ [{:user, value}],
          status: :running
      }
    end
  end

  # decide/2 is a GenServer.call that runs the ENTIRE rest of the turn
  # (LLM round-trips included) — calling it inline would freeze the TUI
  # exactly when the dialog must stay responsive. Run it in a Task; the
  # reply arrives via handle_info({:__decided__, ...}).
  defp decide(state, decision) when decision in [:approve, :reject] do
    sid = state.session_id

    decisions =
      Enum.map(state.pending, fn %{id: id} -> %{id: id, decision: decision} end)

    parent = self()

    Task.start(fn ->
      result =
        case Session.decide(sid, decisions) do
          {:ok, session_state} -> {:ok, session_state.status}
          {:error, reason} -> {:error, reason}
        end

      send(parent, {:__decided__, result})
    end)

    # optimistic UI: dialog closes now, real status arrives with the reply
    %{state | pending: [], pending_edit: nil, status: :running}
  end

  defp forward_to_textarea(state, ev) do
    state = put_in_textarea(state, ev)
    {:noreply, state}
  end

  # The textarea state is a mutable NIF resource: textarea_handle_key
  # returns :ok and mutates in place, so we keep the same reference.
  defp put_in_textarea(state, %Event.Key{} = ev) do
    _ = ExRatatui.textarea_handle_key(state.textarea, ev.code, ev.modifiers || [])
    state
  end

  defp put_in_textarea(state, text) when is_binary(text) do
    # raw text (UTF-8) or bracketed paste: insert at the cursor
    # (native API, in-place)
    _ = ExRatatui.textarea_insert_str(state.textarea, text)
    state
  end

  defp history_step(_state, _dir) do
    # 5c: history navigation through the textarea value setter
    # (needs a value+cursor setter pair; deferred)
  end

  # -- Session events --------------------------------------------------------

  @impl true
  def handle_info({:__decided__, {:ok, status}}, state) do
    {:noreply, %{state | status: status}}
  end

  def handle_info({:__decided__, {:error, reason}}, state) do
    {:noreply, %{state | last_error: reason, status: :error}}
  end

  def handle_info({:agent, {:llm_deltas, delta}}, state) do
    {:noreply, %{state | deltas: state.deltas <> delta}}
  end

  def handle_info({:agent, {:status_changed, status}}, state) do
    {:noreply, %{state | status: status}}
  end

  # :interrupted carries the pending calls as detail — this is how the
  # TUI learns WHAT to render in the approval dialog (a live interrupt
  # during a run; attaching mid-session pulls state on mount instead).
  def handle_info({:agent, {:status_changed, :interrupted, pending}}, state) do
    {:noreply, %{state | status: :interrupted, pending: pending}}
  end

  def handle_info({:agent, {:status_changed, status, _detail}}, state) do
    {:noreply, %{state | status: status}}
  end

  def handle_info({:agent, {:llm_message, text}}, state) do
    {:noreply, %{state | transcript: state.transcript ++ [{:assistant, text}], deltas: ""}}
  end

  def handle_info({:agent, {:tool_executed, name, content}}, state) do
    {:noreply,
     %{state | transcript: state.transcript ++ [{:tool, "▸ #{name}: #{summary(content)}"}]}}
  end

  def handle_info({:agent, {:context_compacted, _keep}}, state) do
    {:noreply, %{state | transcript: state.transcript ++ [{:info, "· context compacted"}]}}
  end

  def handle_info({:__run__, prompt}, state) do
    Task.start(fn -> Session.run(state.session_id, prompt) end)
    {:noreply, %{state | status: :running, transcript: state.transcript ++ [{:user, prompt}]}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Rendering -------------------------------------------------------------

  @impl true
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [transcript_area, input_area, status_area] =
      Layout.split(area, :vertical, [{:min, 0}, {:length, @input_height}, {:length, 1}])

    widgets = [
      {transcript_widget(state), transcript_area},
      {input_widget(state), input_area},
      {status_widget(state), status_area}
    ]

    widgets ++ dialog_widgets(state, area)
  end

  defp transcript_widget(state) do
    lines = Enum.map(state.transcript, &transcript_line/1)

    body =
      if state.deltas == "" do
        Enum.join(lines, "\n")
      else
        Enum.join(lines ++ [streaming_line(state)], "\n")
      end

    %Paragraph{
      text: if(body == "", do: "(type below — enter=newline, alt-enter=send)", else: body),
      style: %Style{fg: :white}
    }
  end

  defp transcript_line({:user, text}), do: "▶ you: " <> text
  defp transcript_line({:assistant, text}), do: "● agent: " <> text
  defp transcript_line({:tool, text}), do: "  " <> text
  defp transcript_line({:info, text}), do: "  " <> text

  defp streaming_line(state), do: "● agent: " <> state.deltas <> "▌"

  defp input_widget(state) do
    %Textarea{
      state: state.textarea,
      placeholder: "Message the agent… (enter=newline, alt-enter=send)",
      line_number_style: nil,
      block: %Block{borders: [:all], border_type: :rounded}
    }
  end

  defp status_widget(state) do
    status_text =
      case state.status do
        :running -> "● running…"
        :idle -> "○ idle"
        :interrupted -> "⏸ approval needed (y/n/e)"
        :error -> "✖ error"
        other -> inspect(other)
      end

    line = "#{state.session_id}  │  #{status_text}"

    %Paragraph{text: line, style: %Style{bg: :dark_gray, fg: :white}, block: nil}
  end

  # Approval dialog: one bordered box per pending call, args pretty-printed.
  defp dialog_widgets(%{pending: []}, _area), do: []

  defp dialog_widgets(%{pending: pending}, area) do
    pending
    |> Enum.with_index()
    |> Enum.map(fn {call, i} ->
      {_id, name, args} = call_info(call)

      body =
        "#{name}(#{pretty_args(args)})\n\n" <>
          "y = approve   n = reject   e = edit (soon)"

      widget = %Paragraph{
        text: body,
        style: %Style{fg: :white},
        block: %Block{
          title: " APPROVAL #{i + 1}/#{length(pending)} ",
          borders: [:all],
          border_type: :double,
          border_style: %Style{fg: :yellow}
        }
      }

      h = min(6 + length(String.split(pretty_args(args), "\n")), div(area.height, 2))
      rect = %Rect{x: 2, y: area.height - h - 3, width: area.width - 4, height: h}
      {widget, rect}
    end)
  end

  defp call_info(%{id: id, name: name, arguments: args}) when is_map(args),
    do: {id, name, args}

  defp call_info(%ReqLLM.ToolCall{id: id, function: %{name: name, arguments: args_json}}) do
    decoded =
      case Jason.decode(args_json) do
        {:ok, m} -> m
        _ -> %{}
      end

    {id, name, decoded}
  end

  defp pretty_args(args) do
    args
    |> Enum.map(fn {k, v} ->
      v_str = if is_binary(v) and String.contains?(v, "\n"), do: inspect(v), else: to_string(v)
      "#{k}: #{String.slice(v_str, 0, 160)}"
    end)
    |> Enum.join("\n")
  end

  defp summary(content) do
    content |> String.split("\n") |> List.first() |> String.slice(0, 80)
  end
end
