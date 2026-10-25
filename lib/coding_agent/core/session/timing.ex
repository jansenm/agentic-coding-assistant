defmodule CodingAgent.Core.Session.Timing do
  @moduledoc """
  Wall time per round (I1): how long the provider call took, and how long
  the work it caused took.

  A ROUND is one provider call plus everything that call caused — the
  policy gate, tool execution, subagents, todo/compact calls. `llm_ms` is
  the call, `tool_ms` is the rest, and the two together are the machine's
  share of a turn: the number that answers "why did this take twenty
  minutes". Human wait is NOT counted: a parked gate, a question, a budget
  dialog or a doom-loop pause stops the clock, because the tool clock
  starts where the round actually runs (`start/1` is called from
  `execute_round/3`, after the human answered).

  Cumulative fields (`rounds`, `llm_ms`, `tool_ms`) cover the session and
  are durable; `turn_*` is the current turn and resets in `begin_turn/1`.
  `last` is the round the sidebar shows, and `started_at` is the
  in-flight phase's monotonic stamp (runtime-only — a snapshot must never
  resurrect it).

  Before this, the only timing a turn had was the TUI's wall clock: a
  200-round turn that took 33 minutes could not say whether the minutes
  sat in the provider or in the tools, so every "why is it slow" answer
  was a guess.
  """

  @fields [
    rounds: 0,
    llm_ms: 0,
    tool_ms: 0,
    turn_rounds: 0,
    turn_llm_ms: 0,
    turn_tool_ms: 0,
    last: nil,
    started_at: nil
  ]
  defstruct @fields

  @typedoc """
  One finished round: its 1-based number in the session and the two
  durations (`tool_ms` is 0 until the round's work finishes).
  """
  @type round :: %{round: pos_integer(), llm_ms: non_neg_integer(), tool_ms: non_neg_integer()}

  @type t :: %__MODULE__{
          rounds: non_neg_integer(),
          llm_ms: non_neg_integer(),
          tool_ms: non_neg_integer(),
          turn_rounds: non_neg_integer(),
          turn_llm_ms: non_neg_integer(),
          turn_tool_ms: non_neg_integer(),
          last: round() | nil,
          started_at: integer() | nil
        }

  @doc "An empty accounting: no round ran yet."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  A timing struct loaded from the store. A nil (an older snapshot) is an
  empty accounting, and an old struct gains the fields it lacks; the
  in-flight stamp never survives a load.
  """
  @spec restore(t() | map() | nil) :: t()
  def restore(timing) when is_map(timing) do
    fields = Map.take(timing, Map.keys(%__MODULE__{}) -- [:__struct__])
    %{struct!(__MODULE__, fields) | started_at: nil}
  end

  def restore(_), do: new()

  @doc "Starts the clock for the phase about to run (a model call or the round's work)."
  @spec start(t()) :: t()
  def start(%__MODULE__{} = timing), do: %{timing | started_at: now()}

  @doc """
  The provider call finished. `ms` is the measured duration; omit it to
  read the clock `start/1` set. Opens the round: `last` becomes this
  round with no tool time yet.
  """
  @spec finish_llm(t(), non_neg_integer() | nil) :: t()
  def finish_llm(%__MODULE__{} = timing, ms \\ nil) do
    ms = elapsed(timing, ms)
    round = timing.rounds + 1

    %{
      timing
      | rounds: round,
        llm_ms: timing.llm_ms + ms,
        turn_rounds: timing.turn_rounds + 1,
        turn_llm_ms: timing.turn_llm_ms + ms,
        last: %{round: round, llm_ms: ms, tool_ms: 0},
        started_at: nil
    }
  end

  @doc """
  The round's work finished. Returns `{timing, round}`, where `round` is
  the round to broadcast — or `nil` when no provider call is open (a
  test-mode round, a steering round): there is nothing to attribute the
  work to, and a stale `last` must not be re-broadcast.
  """
  @spec finish_tools(t(), non_neg_integer() | nil) :: {t(), round() | nil}
  def finish_tools(timing, ms \\ nil)

  def finish_tools(%__MODULE__{last: nil} = timing, _ms), do: {timing, nil}

  def finish_tools(%__MODULE__{} = timing, ms) do
    ms = elapsed(timing, ms)
    round = %{timing.last | tool_ms: ms}

    timing = %{
      timing
      | tool_ms: timing.tool_ms + ms,
        turn_tool_ms: timing.turn_tool_ms + ms,
        last: round,
        started_at: nil
    }

    {timing, round}
  end

  @doc "A new turn: the per-turn counters start over, the session totals keep."
  @spec begin_turn(t()) :: t()
  def begin_turn(%__MODULE__{} = timing) do
    %{
      timing
      | turn_rounds: 0,
        turn_llm_ms: 0,
        turn_tool_ms: 0,
        last: nil,
        started_at: nil
    }
  end

  @doc """
  A duration for the sidebar and `/stats`: `450 ms`, `4.2 s`, `3m 12s`,
  `1h 04m`. The ONE formatting, so the two surfaces cannot print the same
  number differently.
  """
  @spec format_ms(non_neg_integer()) :: String.t()
  def format_ms(ms) when is_integer(ms) and ms >= 0 do
    cond do
      ms < 1_000 -> "#{ms} ms"
      ms < 60_000 -> "#{Float.round(ms / 1000, 1)} s"
      ms < 3_600_000 -> "#{div(ms, 60_000)}m #{pad2(div(rem(ms, 60_000), 1000))}s"
      true -> "#{div(ms, 3_600_000)}h #{pad2(div(rem(ms, 3_600_000), 60_000))}m"
    end
  end

  @doc "The average per round of a counter, rounded to whole milliseconds."
  @spec per_round(non_neg_integer(), t()) :: non_neg_integer()
  def per_round(ms, %__MODULE__{rounds: rounds}) when rounds > 0, do: div(ms, rounds)
  def per_round(_ms, _timing), do: 0

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp elapsed(_timing, ms) when is_integer(ms) and ms >= 0, do: ms
  defp elapsed(%__MODULE__{started_at: nil}, nil), do: 0
  defp elapsed(%__MODULE__{started_at: at}, nil), do: max(now() - at, 0)

  defp now, do: System.monotonic_time(:millisecond)
end
