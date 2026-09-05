defmodule CodingAgent.UI.BridgeTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Bridge

  defp key(code, mods \\ []), do: %ExRatatui.Event.Key{code: code, kind: "press", modifiers: mods}

  test "plain enter maps to :enter / mod :none" do
    assert Bridge.to_keymap_event(key("enter")) == %{key: :enter, mod: :none}
  end

  test "alt-enter maps to :enter / mod :alt (ADR 011 send key)" do
    assert Bridge.to_keymap_event(key("enter", ["alt"])) == %{key: :enter, mod: :alt}
  end

  test "ctrl chords get termbox names with mod :none (ctrl-a -> :ctrl_a)" do
    assert Bridge.to_keymap_event(key("a", ["ctrl"])) == %{key: :ctrl_a, mod: :none}
    assert Bridge.to_keymap_event(key("j", ["ctrl"])) == %{key: :ctrl_j, mod: :none}
    assert Bridge.to_keymap_event(key("k", ["ctrl"])) == %{key: :ctrl_k, mod: :none}
  end

  test "ctrl-enter keeps :enter with mod :ctrl (kitty-protocol hook)" do
    assert Bridge.to_keymap_event(key("enter", ["ctrl"])) == %{key: :enter, mod: :ctrl}
  end

  test "arrows and specials map" do
    assert Bridge.to_keymap_event(key("up")) == %{key: :arrow_up, mod: :none}
    assert Bridge.to_keymap_event(key("page_up")) == %{key: :page_up, mod: :none}
    assert Bridge.to_keymap_event(key("home")) == %{key: :home, mod: :none}
  end

  test "plain letters map to their atoms" do
    assert Bridge.to_keymap_event(key("y")) == %{key: :y, mod: :none}
    assert Bridge.to_keymap_event(key("n")) == %{key: :n, mod: :none}
    assert Bridge.to_keymap_event(key("q")) == %{key: :q, mod: :none}
  end

  test "alt-chord letters: alt-q" do
    assert Bridge.to_keymap_event(key("q", ["alt"])) == %{key: :q, mod: :alt}
  end
end
