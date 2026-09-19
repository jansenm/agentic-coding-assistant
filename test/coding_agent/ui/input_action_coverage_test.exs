defmodule CodingAgent.UI.InputActionCoverageTest do
  @moduledoc """
  Tripwire for the input pipeline (ADR 021: one authority).

  A keymap action must have exactly one owner: either the TUI itself
  (`Tui.handled_input_actions/0`) or the single executor
  (`UI.Editor.editing_action?/1`). Anything else would fall through
  unowned — the class ADR 021 removed.

  This test fails the moment a new action is declared in `Keymap.defaults/0`
  without a decision about who executes it.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.UI.{Editor, Keymap, Tui}

  test "every declared keymap action has exactly one owner" do
    declared =
      Keymap.defaults()
      |> Map.keys()
      |> Enum.reject(&(&1 == :__overridden))

    unowned =
      Enum.reject(declared, fn action ->
        action in Tui.handled_input_actions() or Editor.editing_action?(action)
      end)

    assert unowned == [],
           "keymap actions with no owner: #{inspect(unowned)} — add a " <>
             "`dispatch_input_key` clause or list it in Editor.editing_action?/1"
  end

  test "no action is owned twice" do
    handled = MapSet.new(Tui.handled_input_actions())
    editing = MapSet.new(Enum.filter(Map.keys(Keymap.defaults()), &Editor.editing_action?/1))

    overlap = MapSet.intersection(handled, editing)

    assert MapSet.size(overlap) == 0,
           "actions owned by both the TUI and the Editor: #{inspect(MapSet.to_list(overlap))}"
  end
end
