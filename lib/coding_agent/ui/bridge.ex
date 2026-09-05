defmodule CodingAgent.UI.Bridge do
  @moduledoc """
  Pure translation layer between ExRatatui terminal events and the
  ADR 011 keymap/event model.

  The keymap (CodingAgent.UI.Keymap) maps *actions* against
  `%{key: atom, mod: mod}`; the terminal delivers
  `%ExRatatui.Event.Key{code: string, modifiers: [strings]}`. This
  module is the seam: event → keymap event, so the TUI stays thin and
  both halves stay independently testable.

  Key-name mapping (ADR 011 dialect):
  - "a".."z", digits, " " → :a, :z, :space
  - "enter" → :enter, "esc" → :esc, "tab" → :tab
  - arrows/home/end/page_up/page_down/backspace/delete → same atoms
  - ctrl-chords arrive as code + "ctrl" modifier (e.g. code "a" +
    modifiers ["ctrl"]) → mapped to :ctrl_a (termbox naming), mod :none
    — the ADR 011 default keymap is written in termbox names.
  """

  @modmap %{
    "enter" => :enter,
    "esc" => :esc,
    "tab" => :tab,
    "back_tab" => :back_tab,
    "backspace" => :backspace,
    "delete" => :delete,
    "insert" => :insert,
    "up" => :arrow_up,
    "down" => :arrow_down,
    "left" => :arrow_left,
    "right" => :arrow_right,
    "home" => :home,
    "end" => :end_key,
    "page_up" => :page_up,
    "page_down" => :page_down
  }

  @doc "Terminal key event → keymap event (%{key: atom, mod: mod})."
  @spec to_keymap_event(%ExRatatui.Event.Key{}) :: %{key: atom(), mod: :none | :alt | :ctrl}
  def to_keymap_event(%ExRatatui.Event.Key{code: code, modifiers: modifiers}) do
    mods = MapSet.new(modifiers || [])
    ctrl? = MapSet.member?(mods, "ctrl")
    alt? = MapSet.member?(mods, "alt")

    cond do
      ctrl? and code == "enter" ->
        # the ADR 011 kitty-protocol hook: keep ctrl in mod (the keymap
        # binds :enter + :ctrl as a send alias)
        %{key: :enter, mod: :ctrl}

      ctrl? and modifier_key_name?(code) ->
        # ctrl+arrow etc: keep the name, mark the modifier
        %{key: key_name(code), mod: :ctrl}

      ctrl? ->
        # ctrl chord on a letter: termbox names it distinctly, mod :none
        %{key: ctrl_name(code), mod: :none}

      alt? ->
        %{key: key_name(code), mod: :alt}

      true ->
        %{key: key_name(code), mod: :none}
    end
  end

  # -- names ----------------------------------------------------------------

  defp key_name(code) do
    Map.get(@modmap, code) ||
      if(printable?(code), do: to_safe_atom(code), else: :unknown)
  end

  # Only known-safe atoms: lowercase letters, digits, space. Anything
  # else (uppercase from shifted keys, unicode) stays unmapped — the
  # textarea still receives the raw ev.code for text input; the keymap
  # just won't bind an action to it. binary_to_existing_atom on unknown
  # input crashes the runtime otherwise (found live: shift+C produced
  # code "C", and :C does not exist).
  defp to_safe_atom(code) do
    cond do
      Regex.match?(~r/^[a-z]$/, code) -> String.to_existing_atom(code)
      code == " " -> :space
      Regex.match?(~r/^[0-9]$/, code) -> String.to_existing_atom(code)
      true -> :unknown
    end
  end

  defp ctrl_name(code) do
    # termbox spells chords distinctly: ctrl_a, ctrl_j, ctrl_enter? —
    # ctrl-enter is 0x0D == enter in classic terms; crossterm CAN send
    # enter+ctrl via kitty protocol, so map to :enter with :ctrl kept in
    # mod (ADR 011 future hook). Everything else gets the ctrl_ name.
    case code do
      "enter" ->
        :enter

      other ->
        if Regex.match?(~r/^[a-z]$/, other) do
          String.to_existing_atom("ctrl_" <> other)
        else
          :unknown
        end
    end
  end

  # ctrl modifier on special keys (e.g. ctrl+arrow): keep the arrow
  # name, mod :ctrl (keymap has explicit ctrl-modified arrow patterns).
  defp modifier_key_name?(code), do: Map.has_key?(@modmap, code)

  defp printable?(code) do
    is_binary(code) and code != "" and String.length(code) == 1 and
      String.printable?(code)
  end
end
