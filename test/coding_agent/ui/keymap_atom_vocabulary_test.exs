# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.KeymapAtomVocabularyTest do
  # NOT async: `:erlang.system_info(:atom_count)` is global VM state, so
  # any concurrent test that mints an atom would make this flaky. ExUnit
  # runs sync modules after the async ones, so the count is stable here.
  use ExUnit.Case, async: false

  alias CodingAgent.UI.Keymap

  test "a ui.toml of unknown action and key names mints no atoms (review F1)" do
    # 500 distinct unknown action names, each mapped to an unknown spec
    junk_actions = for i <- 1..500, into: %{}, do: {"junk_action_#{i}", "junk_key_#{i}"}

    # one real action whose spec lists 1000 unknown key names: exercises
    # the to_pattern/1 path (alt-/ctrl-/bare) with unbounded text
    junk_spec =
      1..500
      |> Enum.flat_map(&["alt-junk_#{&1}", "ctrl-junk_#{&1}"])
      |> Enum.join(",")

    # warm every code path once so lazily-loaded modules' atoms are not
    # attributed to the load under test
    {_, _} = Keymap.merge(Keymap.defaults(), junk_actions)
    {_, _} = Keymap.merge(Keymap.defaults(), %{"send_input" => junk_spec})

    before = :erlang.system_info(:atom_count)

    {_actions_map, unknown_actions} = Keymap.merge(Keymap.defaults(), junk_actions)
    {keys_map, unknown_keys} = Keymap.merge(Keymap.defaults(), %{"send_input" => junk_spec})

    assert :erlang.system_info(:atom_count) == before
    assert length(unknown_actions) == 500
    assert unknown_keys == []

    # the real action's binding is inert: every pattern it carries is
    # unknown, so no keypress resolves to send_input
    assert Keymap.resolve(keys_map, %{key: :enter, mod: :alt}) == :unbound
    assert Keymap.resolve(keys_map, %{key: :unknown_key, mod: :none}) == :unbound
  end
end
