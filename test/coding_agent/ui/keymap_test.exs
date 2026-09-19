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

  describe "modifier fallback lattice (review B)" do
    test "a shifted special with no explicit binding falls back to its plain binding" do
      # Regression: mapping every shifted special to :shift used to
      # unbind these, which had worked as their plain keys.
      assert Keymap.resolve(@defaults, %{key: :tab, mod: :shift}) == :switch_agent
      assert Keymap.resolve(@defaults, %{key: :page_up, mod: :shift}) == :scroll_up
      assert Keymap.resolve(@defaults, %{key: :page_down, mod: :shift}) == :scroll_down
    end

    test "an explicit shift binding wins over the fallback (shift+enter)" do
      # This is the whole reason the fallback is ordered
      # specific-before-generic: a blanket shift->none would make
      # shift+enter plain enter and never reach its own binding.
      assert Keymap.resolve(@defaults, %{key: :enter, mod: :shift}) == :insert_newline
      # and plain/alt stay as they were
      assert Keymap.resolve(@defaults, %{key: :enter, mod: :none}) == :insert_newline
      assert Keymap.resolve(@defaults, %{key: :enter, mod: :alt}) == :send_input
    end

    test "alt/ctrl are deliberate chords and do NOT fall back" do
      # ctrl+enter is a send binding; a plain ctrl chord on an unbound
      # special must not silently run the plain action.
      assert Keymap.resolve(@defaults, %{key: :tab, mod: :ctrl}) == :unbound
      assert Keymap.resolve(@defaults, %{key: :page_up, mod: :ctrl}) == :unbound
    end

    test "a shifted letter still falls back (terminal folds shift into the char)" do
      # not a control candidate by itself, but resolve/2 is pure: given
      # :a+shift it must find the plain :a binding if one exists
      {km, _} = Keymap.merge(@defaults, %{"insert_newline" => "a"})
      assert Keymap.resolve(km, %{key: :a, mod: :shift}) == :insert_newline
    end
  end
end
