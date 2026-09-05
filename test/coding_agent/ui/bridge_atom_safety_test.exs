defmodule CodingAgent.UI.BridgeAtomSafetyTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Bridge

  # Regression (found live): shift+C delivers code "C";
  # binary_to_existing_atom("C") crashed the whole runtime.

  test "uppercase codes do not crash and map to :unknown" do
    assert Bridge.to_keymap_event(%ExRatatui.Event.Key{
             code: "C",
             kind: "press",
             modifiers: ["shift"]
           }) ==
             %{key: :unknown, mod: :none}
  end

  test "uppercase without shift too (caps lock)" do
    assert Bridge.to_keymap_event(%ExRatatui.Event.Key{code: "Q", kind: "press", modifiers: []}) ==
             %{key: :unknown, mod: :none}
  end

  test "unknown-key codes (unicode, named) do not crash" do
    assert Bridge.to_keymap_event(%ExRatatui.Event.Key{code: "ä", kind: "press", modifiers: []}) ==
             %{key: :unknown, mod: :none}

    assert Bridge.to_keymap_event(%ExRatatui.Event.Key{
             code: "media_play",
             kind: "press",
             modifiers: []
           }) ==
             %{key: :unknown, mod: :none}
  end

  test "ctrl + non-letter does not crash" do
    assert Bridge.to_keymap_event(%ExRatatui.Event.Key{
             code: "C",
             kind: "press",
             modifiers: ["ctrl"]
           }) ==
             %{key: :unknown, mod: :none}
  end

  test "lowercase letters, digits and space still map" do
    assert Bridge.to_keymap_event(%ExRatatui.Event.Key{code: "y", kind: "press", modifiers: []}) ==
             %{key: :y, mod: :none}

    assert Bridge.to_keymap_event(%ExRatatui.Event.Key{code: "1", kind: "press", modifiers: []}) ==
             %{key: :"1", mod: :none}

    assert Bridge.to_keymap_event(%ExRatatui.Event.Key{code: " ", kind: "press", modifiers: []}) ==
             %{key: :space, mod: :none}
  end
end
