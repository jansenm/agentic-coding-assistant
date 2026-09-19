defmodule CodingAgent.UI.TuiCursorTest do
  @moduledoc """
  Regression: the input cursor must be visible.

  Found live: "you cannot see where you are typing". The cursor is a CELL
  STYLE, not a hardware cursor, and `tui-textarea`'s own default is
  REVERSED — but `%ExRatatui.Widgets.Textarea{}` defaults `cursor_style`
  to an EMPTY `%Style{}`, and the bridge always encodes the field, so the
  empty style overwrote the crate default and painted nothing.

  The text buffer (`get_buffer_content/1`) carries characters, not cell
  attributes, so the honest assertion is on the widget `render/2` builds:
  it must carry the reversed modifier.
  """
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.UI.Tui

  test "the input Textarea carries a visible (reversed) cursor style" do
    pid = start_supervised!({Tui, name: nil, test_mode: {100, 40}, scope_root: File.cwd!()})

    widgets = Tui.render(sync(pid), %ExRatatui.Frame{width: 100, height: 40})

    textareas =
      for {widget, _rect} <- widgets, match?(%ExRatatui.Widgets.Textarea{}, widget), do: widget

    assert [%ExRatatui.Widgets.Textarea{} = ta] = textareas
    assert ta.cursor_style.modifiers == [:reversed]
    # the cursor-line highlight stays deliberately empty (a reversed char
    # is enough; a full-line highlight is noisy in a multi-line composer)
    assert ta.cursor_line_style.modifiers == []
  end
end
