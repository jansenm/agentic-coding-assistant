defmodule CodingAgent.UI.InputActionCoverageTest do
  @moduledoc """
  Tripwire for the input pipeline (review D class).

  A keymap action must be either **handled** by `Tui.dispatch_input_key/3`
  or explicitly **delegated** to the textarea crate. Anything else falls
  through the wildcard as raw text — silently performing neither the
  keymap's claim nor an intentional delegation.

  This test fails the moment a new action is declared in `Keymap.defaults/0`
  without a decision about who executes it. It is the assertion that would
  have caught the decorative `:cursor_*` / `:kill_*` actions and the
  accidental text fall-through.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.UI.{Keymap, Tui}

  test "every declared keymap action is handled or explicitly delegated" do
    declared =
      Keymap.defaults()
      |> Map.keys()
      |> Enum.reject(&(&1 == :__overridden))
      |> MapSet.new()

    covered =
      (Tui.handled_input_actions() ++ Tui.delegated_input_actions())
      |> MapSet.new()

    missing = MapSet.difference(declared, covered)

    assert MapSet.size(missing) == 0,
           "keymap actions with no TUI clause and no delegation: " <>
             "#{inspect(MapSet.to_list(missing))} — add a `dispatch_input_key` " <>
             "clause or list it in @delegated_input_actions"
  end

  test "handled and delegated do not overlap" do
    overlap =
      MapSet.intersection(
        MapSet.new(Tui.handled_input_actions()),
        MapSet.new(Tui.delegated_input_actions())
      )

    assert MapSet.size(overlap) == 0,
           "actions both handled and delegated (ambiguous authority): #{inspect(MapSet.to_list(overlap))}"
  end
end
