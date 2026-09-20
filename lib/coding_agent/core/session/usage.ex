defmodule CodingAgent.Core.Session.Usage do
  @moduledoc """
  Cumulative session token accounting (P3 factoring).

  One home for `last_input_tokens` semantics and the defaults. Before this
  the shape lived as a bare map literal `%{input_tokens: 0, output_tokens:
  0, cost: nil}` copied across the session, the state default, the TUI and
  the tests, and the accumulation rule sat inside the turn loop.

  `last_input_tokens` is the **last turn's** input count, not the
  cumulative one: it is the honest context-size measure the provider
  actually saw, so it is what compaction triggers on. Cumulative
  `input_tokens`/`output_tokens` drive the sidebar totals; `cost` is nil
  when the provider does not price.

  ## Persistence

  Older snapshots stored a plain map. `from_map/1` normalizes a loaded
  map (or a struct, or nil) into a `%Usage{}`, so the struct is a
  wire-compatible upgrade — no snapshot migration needed.
  """

  @enforce_keys []
  defstruct input_tokens: 0, output_tokens: 0, last_input_tokens: 0, cost: nil

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          last_input_tokens: non_neg_integer(),
          cost: number() | nil
        }

  @doc "Fresh, all-zero usage (the single default)."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Normalizes a persisted/loose value into a `%Usage{}`: a `%Usage{}` is
  returned as-is, a map is read with defaults, nil/missing gives `new/0`.
  """
  @spec from_map(t() | map() | nil) :: t()
  def from_map(%__MODULE__{} = usage), do: usage

  def from_map(nil), do: new()

  def from_map(map) when is_map(map) do
    %__MODULE__{
      input_tokens: Map.get(map, :input_tokens, 0),
      output_tokens: Map.get(map, :output_tokens, 0),
      last_input_tokens: Map.get(map, :last_input_tokens, 0),
      cost: Map.get(map, :cost)
    }
  end

  @doc "Cumulative input tokens (the sidebar total)."
  @spec input_tokens(t() | map() | nil) :: non_neg_integer()
  def input_tokens(usage), do: from_map(usage).input_tokens

  @doc "Cumulative output tokens."
  @spec output_tokens(t() | map() | nil) :: non_neg_integer()
  def output_tokens(usage), do: from_map(usage).output_tokens

  @doc "The last turn's input count — the compaction measure."
  @spec last_input_tokens(t() | map() | nil) :: non_neg_integer()
  def last_input_tokens(usage), do: from_map(usage).last_input_tokens

  @doc """
  Accumulates one turn's provider usage (a plain map from ReqLLM, keys
  `:input_tokens`/`:output_tokens`/`:total_cost`).

  A nil/zero input count (interrupted or error turn, provider usage
  missing) does NOT clobber the previous honest `last_input_tokens`: a
  zero here silently re-armed the chars-based compaction fallback on a
  fat context (found live: a resumed session compacted at 212K chars
  while the sidebar showed 58.3k).
  """
  @spec add(t(), map() | nil) :: t()
  def add(usage, nil), do: from_map(usage)

  def add(usage, turn) when is_map(turn) do
    prev = from_map(usage)

    last_in =
      case turn[:input_tokens] do
        n when is_integer(n) and n > 0 -> n
        _ -> prev.last_input_tokens
      end

    %__MODULE__{
      input_tokens: prev.input_tokens + (turn[:input_tokens] || 0),
      output_tokens: prev.output_tokens + (turn[:output_tokens] || 0),
      last_input_tokens: last_in,
      cost: sum_cost(prev.cost, turn[:total_cost])
    }
  end

  defp sum_cost(nil, nil), do: nil
  defp sum_cost(a, b), do: (a || 0.0) + (b || 0.0)
end
