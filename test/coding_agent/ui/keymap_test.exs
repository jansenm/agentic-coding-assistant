defmodule CodingAgent.UI.KeymapTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Keymap

  @defaults Keymap.defaults()

  test "enter inserts a newline by default (ADR 011)" do
    assert Keymap.resolve(@defaults, %{key: :enter, mod: :none}) == :insert_newline
  end

  test "alt-enter sends" do
    assert Keymap.resolve(@defaults, %{key: :enter, mod: :alt}) == :send_input
  end

  test "ctrl-enter sends (when a terminal ever delivers it)" do
    assert Keymap.resolve(@defaults, %{key: :enter, mod: :ctrl}) == :send_input
  end

  test "unknown key resolves to :unbound" do
    assert Keymap.resolve(@defaults, %{key: :f1, mod: :none}) == :unbound
  end

  test "readline bindings per ADR 006" do
    assert Keymap.resolve(@defaults, %{key: :ctrl_a, mod: :none}) == :cursor_home
    assert Keymap.resolve(@defaults, %{key: :ctrl_e, mod: :none}) == :cursor_end
    assert Keymap.resolve(@defaults, %{key: :ctrl_k, mod: :none}) == :kill_to_end
    assert Keymap.resolve(@defaults, %{key: :ctrl_p, mod: :none}) == :history_prev
  end

  test "merge overrides defaults; missing :mod means none" do
    {km, warnings} =
      Keymap.merge(@defaults, %{
        "insert_newline" => "ctrl-j",
        "send_input" => "enter"
      })

    assert Keymap.resolve(km, %{key: :enter, mod: :none}) == :send_input
    assert Keymap.resolve(km, %{key: :ctrl_j, mod: :none}) == :insert_newline
    assert warnings == []
  end

  test "merge reports unknown actions and ignores them" do
    {km, warnings} = Keymap.merge(@defaults, %{"send-input" => "enter", "banana" => "x"})
    assert Keymap.resolve(km, %{key: :enter, mod: :none}) == :send_input
    assert warnings == ["banana"]
  end

  test "merge parses alt- and ctrl- prefixed specs" do
    {km, _} = Keymap.merge(@defaults, %{"send-input" => "alt-enter,ctrl-m"})
    assert Keymap.resolve(km, %{key: :enter, mod: :alt}) == :send_input
    assert Keymap.resolve(km, %{key: :ctrl_m, mod: :none}) == :send_input
  end
end
