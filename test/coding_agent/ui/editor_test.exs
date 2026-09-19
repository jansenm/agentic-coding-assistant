defmodule CodingAgent.UI.EditorTest do
  @moduledoc """
  Tests for the one input executor (ADR 021).

  The intent → crate mapping is grounded in probes against the vendored
  `tui-textarea`; these tests pin the behavior so the keymap's claims
  (`:kill_line`, `:insert_newline`, …) are what actually happens — the
  opposite of the two-authority situation the review found.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Editor

  # set the value, place the cursor at the end (set_value leaves it at
  # 0,0; move to the line end), then apply an intent.
  defp run(text, intent) do
    ta = ExRatatui.textarea_new()
    ExRatatui.textarea_set_value(ta, text)
    ExRatatui.textarea_handle_key(ta, "end", [])
    :ok = Editor.apply(ta, intent)
    ExRatatui.textarea_get_value(ta)
  end

  test "insert_text inserts at the cursor" do
    assert run("ab", {:text, "X"}) == "abX"
  end

  test "insert_newline is a newline, never a deletion" do
    # The old bug: ctrl-j (declared :insert_newline) fell through to the
    # crate and ran delete_line_by_head. The editor guarantees newline.
    assert run("ab", :insert_newline) == "ab\n"
  end

  test "backspace deletes the char before the cursor" do
    assert run("abc", :backspace) == "ab"
  end

  test "kill_to_end deletes from the cursor to the line end" do
    assert run("hello world", :kill_to_end) == "hello world"
    # from the start of the line it clears everything
    ta = ExRatatui.textarea_new()
    ExRatatui.textarea_set_value(ta, "hello")
    :ok = Editor.apply(ta, :kill_to_end)
    assert ExRatatui.textarea_get_value(ta) == ""
  end

  test "kill_word deletes the word before the cursor" do
    assert run("hello world", :kill_word) == "hello "
  end

  test "kill_line clears the whole line even from the middle" do
    # The old bug: ctrl-u (declared :kill_line) ran undo. kill_line is
    # composed (home + kill-to-end) because the crate has no single
    # binding for it.
    ta = ExRatatui.textarea_new()
    ExRatatui.textarea_set_value(ta, "hello world")
    ExRatatui.textarea_handle_key(ta, "home", [])
    for _ <- 1..5, do: ExRatatui.textarea_handle_key(ta, "right", [])
    :ok = Editor.apply(ta, :kill_line)
    assert ExRatatui.textarea_get_value(ta) == ""
  end

  test "cursor moves match the keymap names" do
    assert run("abc", :cursor_home) == "abc"
    assert Editor.apply(ExRatatui.textarea_new(), :cursor_end) == :ok
  end

  test "every editing action the keymap can declare is handled here" do
    # The complement of Tui.handled_input_actions/0; the coverage test
    # asserts the partition, this asserts the executor accepts each one.
    for intent <- [
          :insert_newline,
          :backspace,
          :delete,
          :cursor_home,
          :cursor_end,
          :cursor_up,
          :cursor_down,
          :cursor_left,
          :cursor_right,
          :kill_to_end,
          :kill_word,
          :kill_line
        ] do
      assert Editor.editing_action?(intent)
      assert :ok = Editor.apply(ExRatatui.textarea_new(), intent)
    end
  end

  test "an unknown intent raises instead of silently doing nothing" do
    assert_raise ArgumentError, fn ->
      Editor.apply(ExRatatui.textarea_new(), :not_an_intent)
    end
  end
end
