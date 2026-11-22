# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.TuiShiftEnterTest do
  @moduledoc """
  Regression: shift+enter (B2) must be defined, not silently dropped.

  Found live: "shift+enter does something strange; typed text
  disappears." Root cause at the vocabulary level: `:shift` was not part
  of the event model, so `Bridge.translate/2` dropped it and shift+enter
  was indistinguishable from enter — while the RAW event (with the shift
  modifier list) was still forwarded to the textarea, so the keymap and
  the textarea disagreed about the same keypress.

  Wire encodings differ by terminal, so each is pinned here:

    * kitty / meta protocol reports `enter` with a `shift` modifier
      (crossterm decodes it; the bridge now keeps `:shift`);
    * a shifted letter arrives as its UPPERCASE char, not as a modifier;
    * legacy terminals send shift+enter as the SAME bytes as alt+enter
      (`ESC CR`), which crossterm reports as `enter` + `alt` — the wire
      cannot tell them apart, so there shift+enter IS send.

  ADR 011 is composition-first: where shift IS reported, shift+enter
  inserts a newline (the common reflex), like plain enter.
  """
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.Tui

  defp start_tui do
    start_supervised!(%{
      id: :shift_tui,
      start: {Tui, :start_link, [[name: nil, test_mode: {100, 40}, scope_root: File.cwd!()]]}
    })
  end

  test "kitty encoding: enter+shift inserts a newline, does not send" do
    pid = start_tui()

    ExRatatui.textarea_insert_str(sync(pid).textarea, "hello")
    key(pid, "enter", ["shift"])

    st = sync(pid)
    assert ExRatatui.textarea_get_value(st.textarea) == "hello\n"
    # NOT sent: no transcript entry, still idle
    assert st.transcript == []
    assert st.status == :idle
  end

  test "a shifted letter is text (uppercase), never a shift special" do
    pid = start_tui()

    ExRatatui.textarea_insert_str(sync(pid).textarea, "a")
    key(pid, "B", ["shift"])

    assert ExRatatui.textarea_get_value(sync(pid).textarea) == "aB"
  end

  test "legacy encoding: ESC CR is enter+alt, which IS send" do
    pid = start_tui()

    ExRatatui.textarea_insert_str(sync(pid).textarea, "do it")

    # the legacy shift+enter bytes decode to enter+alt — the send key
    key(pid, "enter", ["alt"])

    st = sync(pid)
    assert st.status == :running
    assert Enum.any?(st.transcript, &match?({:user, "do it"}, &1))
  end

  test "ctrl-enter still sends (the kitty hook is preserved)" do
    pid = start_tui()

    ExRatatui.textarea_insert_str(sync(pid).textarea, "go")
    key(pid, "enter", ["ctrl"])

    st = sync(pid)
    assert st.status == :running
    assert Enum.any?(st.transcript, &match?({:user, "go"}, &1))
  end

  test "the raw shift modifier is never forwarded to the textarea" do
    # The two layers used to disagree: the keymap saw enter with no
    # shift while the textarea got the raw event WITH shift. Now the
    # keymap owns shift+enter; forwarding stays byte-identical to plain
    # enter, so the textarea never sees a modifier the keymap dropped.
    pid = start_tui()

    ExRatatui.textarea_insert_str(sync(pid).textarea, "x")
    key(pid, "enter", ["shift"])
    key(pid, "enter")

    # exactly two newlines, no third from a double-insert
    assert ExRatatui.textarea_get_value(sync(pid).textarea) == "x\n\n"
  end
end
