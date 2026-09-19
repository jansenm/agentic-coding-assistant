defmodule CodingAgent.UI.BridgeTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Bridge

  defp key(code, mods \\ []), do: %ExRatatui.Event.Key{code: code, kind: "press", modifiers: mods}

  # the letters the TUI keymap actually binds (defaults + decision keys)
  @bound Bridge.bound_letters(CodingAgent.UI.Keymap.defaults()) ++
           Bridge.bound_letters(%{
             approve: [%{key: :y, mod: :none}],
             reject: [%{key: :n, mod: :none}],
             edit: [%{key: :e, mod: :none}]
           })

  describe "control tier" do
    test "enter is a keymap event" do
      assert Bridge.translate(key("enter"), @bound) == {:key, %{key: :enter, mod: :none}}
    end

    test "alt-enter is the ADR 011 send key" do
      assert Bridge.translate(key("enter", ["alt"]), @bound) == {:key, %{key: :enter, mod: :alt}}
    end

    test "ctrl chords get synthesized ctrl_ names" do
      assert Bridge.translate(key("a", ["ctrl"]), @bound) == {:key, %{key: :ctrl_a, mod: :none}}
      assert Bridge.translate(key("j", ["ctrl"]), @bound) == {:key, %{key: :ctrl_j, mod: :none}}
    end

    test "shift is kept for specials (it is not folded into the code there)" do
      assert Bridge.translate(key("enter", ["shift"]), @bound) ==
               {:key, %{key: :enter, mod: :shift}}

      assert Bridge.translate(key("up", ["shift"]), @bound) ==
               {:key, %{key: :arrow_up, mod: :shift}}
    end

    test "ctrl-enter keeps mod :ctrl (kitty hook)" do
      assert Bridge.translate(key("enter", ["ctrl"]), @bound) ==
               {:key, %{key: :enter, mod: :ctrl}}
    end

    test "bound letters are keymap events" do
      assert Bridge.translate(key("y"), @bound) == {:key, %{key: :y, mod: :none}}
      assert Bridge.translate(key("n"), @bound) == {:key, %{key: :n, mod: :none}}
    end

    test "alt chords on any letter are key candidates (unbound ones resolve :unbound)" do
      assert Bridge.translate(key("q", ["alt"]), @bound) == {:key, %{key: :q, mod: :alt}}
    end

    test "arrows and specials map" do
      assert Bridge.translate(key("up"), @bound) == {:key, %{key: :arrow_up, mod: :none}}
      assert Bridge.translate(key("page_up"), @bound) == {:key, %{key: :page_up, mod: :none}}
      assert Bridge.translate(key("home"), @bound) == {:key, %{key: :home, mod: :none}}
    end
  end

  describe "text tier (full UTF-8, never atomized)" do
    test "unbound lowercase letters are text" do
      assert Bridge.translate(key("o"), @bound) == {:text, "o"}
      assert Bridge.translate(key("a"), @bound) == {:text, "a"}
    end

    test "uppercase is text (shift)" do
      assert Bridge.translate(key("C", ["shift"]), @bound) == {:text, "C"}
      assert Bridge.translate(key("Q"), @bound) == {:text, "Q"}
    end

    test "UTF-8 is text: umlauts, accents, emoji" do
      assert Bridge.translate(key("ä"), @bound) == {:text, "ä"}
      assert Bridge.translate(key("é"), @bound) == {:text, "é"}
      assert Bridge.translate(key("😀"), @bound) == {:text, "😀"}
      assert Bridge.translate(key("文"), @bound) == {:text, "文"}
    end

    test "space is text (it types a space)" do
      assert Bridge.translate(key(" "), @bound) == {:text, " "}
    end

    test "digits are text" do
      assert Bridge.translate(key("1"), @bound) == {:text, "1"}
    end
  end

  describe "bound_letters/1" do
    test "reads single-letter bindings from the keymap, ignores others" do
      letters = Bridge.bound_letters(CodingAgent.UI.Keymap.defaults())
      # 5b->5c rebalance: NO single letters are bound in the default
      # keymap anymore (letters are for typing; approval keys live in
      # the decision keymap, quit/abort are ctrl-chords)
      assert letters == []
    end
  end
end
