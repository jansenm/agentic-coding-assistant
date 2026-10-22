defmodule CodingAgent.Core.Session.ContextBudget do
  @moduledoc """
  The context-budget block as DATA (ADR 040): the numbers one request tells
  the model about its context window, and the threshold at which the block
  starts advising.

  It was a bare map built in `Session.budget_info/1` and matched field by
  field in `Prompt.with_budget/2`, which made every field optional at
  compile time. A producer that forgot `warn_at` silently lost the band
  advice — no warning, no test outside the prompt module — and a producer
  that renamed a key produced a block with a missing number. Seven facts
  travel between two modules; the struct is the one place they are stated
  once.

  Every field is REQUIRED (`@enforce_keys`): all of them are known when a
  request is assembled. This is a value object for one provider call, not
  partial state that fills in over time, so there is no sensible default
  for any of them — a `%ContextBudget{}` with `window: 0` would be a block
  that renders a lie, and `0` is exactly what a default would put there.

  `from_state/2` is the production constructor. The one field it cannot
  read from the session state alone is `max_rounds` — the tool-round budget
  the guard checks, resolved agent → session → config by
  `Session.tool_budget/1` — so the caller passes it in. That keeps ONE
  resolution feeding both the number shown and the number enforced (review
  N66), and keeps the config read out of a value object.
  """

  alias CodingAgent.Core.Session.{Compactor, State}

  @enforce_keys [:used, :window, :soft, :hard, :warn_at, :rounds, :max_rounds]
  defstruct [:used, :window, :soft, :hard, :warn_at, :rounds, :max_rounds]

  @typedoc """
  One request's budget, as the model is told it.

    * `used` — the PROJECTED context size (`Compactor.projected_tokens/1`),
      the same number the compaction decision uses;
    * `window` / `soft` / `hard` — the resolved window and the two lines
      (`Compactor.window/1`, `soft_limit/1`, `hard_limit/1`);
    * `warn_at` — the threshold at which the block advises: the SAME
      number the human's approaching note fires on
      (`Compactor.warn_threshold/1`), so advice and note cannot drift
      (ADR 029, ADR 040 amendment 2026-10-22);
    * `rounds` / `max_rounds` — the tool-round budget the guard checks
      (ADR 025); `max_rounds` may be far larger than `rounds`, but it is
      never unbounded: `Config.max_tool_rounds/1` supplies the floor.
  """
  @type t :: %__MODULE__{
          used: non_neg_integer(),
          window: pos_integer(),
          soft: pos_integer(),
          hard: pos_integer(),
          warn_at: non_neg_integer(),
          rounds: non_neg_integer(),
          max_rounds: pos_integer()
        }

  @doc """
  Builds the block for one request from the SAME state the sidebar mirrors
  and the compaction decision uses (ADR 029 — the display must not show a
  different value than the decision), plus the guard's resolved
  tool-round budget.
  """
  @spec from_state(State.t(), pos_integer()) :: t()
  def from_state(%State{} = state, max_rounds) when is_integer(max_rounds) and max_rounds > 0 do
    %__MODULE__{
      used: Compactor.projected_tokens(state),
      window: Compactor.window(state),
      soft: Compactor.soft_limit(state),
      hard: Compactor.hard_limit(state),
      warn_at: Compactor.warn_threshold(state),
      rounds: state.tool_rounds,
      max_rounds: max_rounds
    }
  end
end
