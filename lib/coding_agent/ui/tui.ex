defmodule CodingAgent.UI.Tui do
  @moduledoc """
  The phase-5 terminal UI driver (5a slice): alt-screen transcript +
  status line over one Core session.

  ADR 012 boundary: this module owns nothing about the agent loop —
  it starts a `CodingAgent.Core.Session`, subscribes to the event
  registry (exactly like the CLI does), and renders what arrives.
  Input editing arrives in 5b; for now `q` quits.
  """

  use ExRatatui.App

  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.Supervisor
  alias CodingAgent.Core.Session.Store
  alias ExRatatui.Event
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Paragraph

  @status_height 1

  @impl true
  def mount(opts) do
    id = Keyword.get(opts, :session_id) || "tui-#{System.unique_integer([:positive])}"
    prompt = Keyword.get(opts, :initial_prompt)

    with {:ok, _pid} <- start_session(id, opts) do
      Session.subscribe(id)

      initial = %{
        session_id: id,
        status: :idle,
        transcript: [],
        deltas: "",
        last_error: nil
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

  # -- Events ----------------------------------------------------------------

  @impl true
  def handle_event(%Event.Key{code: "q", kind: "press"}, state) do
    {:stop, state}
  end

  def handle_event(_event, state) do
    {:noreply, state}
  end

  # Session events (from Core's EventRegistry): identical shapes the
  # CLI consumes — this module is a pure consumer.
  @impl true
  def handle_info({:agent, {:llm_deltas, delta}}, state) do
    {:noreply, %{state | deltas: state.deltas <> delta}}
  end

  def handle_info({:agent, {:status_changed, status}}, state) do
    {:noreply, %{state | status: status}}
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
    {:noreply,
     state
     |> Map.put(:deltas, "")
     |> Map.put(:transcript, state.transcript ++ [{:info, "· context compacted"}])}
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

    [transcript_area, status_area] =
      ExRatatui.Layout.split(area, :vertical, [{:min, 0}, {:length, @status_height}])

    [
      {transcript_widget(state), transcript_area},
      {status_widget(state), status_area}
    ]
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
      text: if(body == "", do: "(empty — type q to quit)", else: body),
      style: %Style{fg: :white}
    }
  end

  defp transcript_line({:user, text}), do: "▶ you: " <> text
  defp transcript_line({:assistant, text}), do: "● agent: " <> text
  defp transcript_line({:tool, text}), do: "  " <> text
  defp transcript_line({:info, text}), do: "  " <> text

  defp streaming_line(state), do: "● agent: " <> state.deltas <> "▌"

  defp status_widget(state) do
    status_text =
      case state.status do
        :running -> "● running…"
        :idle -> "○ idle"
        :interrupted -> "⏸ waiting for YOUR decision"
        :error -> "✖ error"
        other -> inspect(other)
      end

    line =
      "#{state.session_id}  │  #{status_text}  │  q: quit"

    %Paragraph{
      text: line,
      style: %Style{bg: :dark_gray, fg: :white},
      block: nil
    }
  end

  defp summary(content) do
    content
    |> String.split("\n")
    |> List.first()
    |> String.slice(0, 80)
  end
end
