# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.Editor do
  @moduledoc """
  The one executor for input edits (ADR 021: one authority).

  Before this module the input pipeline had two authorities: our
  `Keymap` and the textarea crate's own Emacs bindings. The TUI
  forwarded the **raw** terminal event to the crate
  (`textarea_handle_key/3`), so any key the keymap did not intercept was
  performed by the crate with different semantics. Measured divergences:
  `ctrl-j` (the keymap's `:insert_newline`) ran `delete_line_by_head`
  and wiped the line; `ctrl-u` (the keymap's `:kill_line`) ran `undo`.

  This module removes the second authority: the TUI names an **intent**
  and this executor performs it. The raw event never reaches the crate.
  Each intent maps to a measured crate operation; where the crate has no
  single binding for the intent, the intent is composed from measured
  operations (`:kill_line` = home + kill-to-end).

  The intent → crate mapping is grounded in probes against the vendored
  `tui-textarea` (`textarea_handle_key/3`), not assumed from its docs:

  | intent | crate call | effect |
  |---|---|---|
  | `:insert_newline` | `enter` | newline at the cursor |
  | `:backspace` | `backspace` | delete the char before the cursor |
  | `:delete` | `delete` | delete the char at the cursor |
  | `:cursor_*` | `home`/`end`/`up`/`down`/`left`/`right` | move the cursor |
  | `:kill_to_end` | `k` + ctrl | delete from the cursor to end of line |
  | `:kill_word` | `w` + ctrl | delete the word before the cursor |
  | `:kill_line` | `home`, `k` + ctrl | delete the whole line |

  `:kill_line` composes because the crate binds no single key to
  "delete the line" (`ctrl-u` is `undo`). Composition keeps the crate as
  the buffer owner, so undo/selection still work; the alternative — an
  own buffer — is ADR 021's option 2, revisited if soft wrap (B5) needs
  it.
  """

  @typedoc """
  An edit to apply to the textarea buffer.

  The intent names mirror `Keymap.action/0` for the editing subset, so
  the mapping in the TUI is identity and a new editing action is
  impossible to forget here.
  """
  @type intent ::
          {:text, String.t()}
          | :insert_newline
          | :backspace
          | :delete
          | :cursor_home
          | :cursor_end
          | :cursor_up
          | :cursor_down
          | :cursor_left
          | :cursor_right
          | :kill_to_end
          | :kill_word
          | :kill_line

  @doc "Applies one edit to the textarea buffer. Returns `:ok`."
  @spec apply(reference(), intent()) :: :ok
  def apply(textarea, {:text, text}), do: ExRatatui.textarea_insert_str(textarea, text)

  def apply(textarea, intent), do: Enum.each(nifs(intent), &handle(textarea, &1))

  @doc """
  Whether `action` is an editing action this executor owns. The single
  source of truth the TUI partitions against.
  """
  @spec editing_action?(atom()) :: boolean()
  def editing_action?(action) do
    action in [
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
    ]
  end

  # The measured crate call(s) for an intent. A list because `:kill_line`
  # needs two (home, then kill-to-end).
  defp nifs(:insert_newline), do: [{"enter", []}]
  defp nifs(:backspace), do: [{"backspace", []}]
  defp nifs(:delete), do: [{"delete", []}]
  defp nifs(:cursor_home), do: [{"home", []}]
  defp nifs(:cursor_end), do: [{"end", []}]
  defp nifs(:cursor_up), do: [{"up", []}]
  defp nifs(:cursor_down), do: [{"down", []}]
  defp nifs(:cursor_left), do: [{"left", []}]
  defp nifs(:cursor_right), do: [{"right", []}]
  defp nifs(:kill_to_end), do: [{"k", ["ctrl"]}]
  defp nifs(:kill_word), do: [{"w", ["ctrl"]}]
  defp nifs(:kill_line), do: [{"home", []}, {"k", ["ctrl"]}]

  defp nifs(other), do: raise(ArgumentError, "unknown editor intent: #{inspect(other)}")

  defp handle(textarea, {code, mods}) do
    _ = ExRatatui.textarea_handle_key(textarea, code, mods)
    :ok
  end
end
