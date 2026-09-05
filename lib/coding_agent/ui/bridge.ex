defmodule CodingAgent.UI.Bridge do
  @moduledoc """
  Pure translation layer between ExRatatui terminal events and the
  ADR 011 keymap/event model.

  Two-tier design (the UTF-8 lesson from live use — do not conflate
  text with control keys):

  - **Control candidates**: special keys (enter, arrows, ctrl chords…)
    — translated into keymap events `%{key: atom, mod: mod}` and
    resolved against the keymap. Atoms come from a fixed name set
    (specials map + bound letters), so atom growth is bounded by the
    keymap, not by typing.
  - **Everything else is TEXT** — full UTF-8 (letters, uppercase,
    accents, emoji, CJK) is forwarded raw to the Textarea and never
    atomized. The keymap never sees it, so there is no crash class to
    guard against: an `ä` is not `:unknown`, it is simply not a
    control key.

  The letters that count as control candidates come FROM the keymap
  itself (`bound_letters/1`): the keymap is data, so binding `:å` as
  an action key would just work.
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

  @typedoc "What the bridge decided an event is."
  @type translated ::
          {:key, %{key: atom(), mod: :none | :alt | :ctrl}}
          | {:text, String.t()}

  @doc """
  Translates a terminal key event: `{:key, event}` when it is a keymap
  candidate (special keys or a letter the keymap binds), `{:text, code}`
  otherwise. Text is never atomized.
  """
  @spec translate(%ExRatatui.Event.Key{}, [atom()]) :: translated()
  def translate(%ExRatatui.Event.Key{code: code, modifiers: modifiers}, bound_letters) do
    mods = MapSet.new(modifiers || [])
    ctrl? = MapSet.member?(mods, "ctrl")
    alt? = MapSet.member?(mods, "alt")

    cond do
      special?(code) ->
        {:key, key_event(code, ctrl?, alt?)}

      # a chord (ctrl/alt) on a letter is ALWAYS a control candidate —
      # the keymap may or may not bind it, but it must get the chance
      ctrl? and single_lowercase?(code) ->
        {:key, key_event(code, ctrl?, alt?)}

      alt? and single_lowercase?(code) ->
        {:key, key_event(code, ctrl?, alt?)}

      single_lowercase?(code) and String.to_atom(code) in bound_letters ->
        {:key, key_event(code, ctrl?, alt?)}

      true ->
        # text: any single printable char in full UTF-8; the textarea
        # inserts it verbatim
        {:text, code}
    end
  end

  # -- keymap events (control tier) -----------------------------------------

  defp key_event(code, ctrl?, alt?) do
    cond do
      ctrl? and code == "enter" ->
        # ADR 011 kitty-protocol hook: keep ctrl in mod
        %{key: :enter, mod: :ctrl}

      ctrl? and Map.has_key?(@modmap, code) ->
        # ctrl+arrow etc: keep the name, mark the modifier
        %{key: Map.fetch!(@modmap, code), mod: :ctrl}

      ctrl? ->
        %{key: ctrl_name(code), mod: :none}

      alt? ->
        %{key: name(code), mod: :alt}

      true ->
        %{key: name(code), mod: :none}
    end
  end

  defp name(code) do
    cond do
      Map.has_key?(@modmap, code) -> Map.fetch!(@modmap, code)
      single_lowercase?(code) -> String.to_atom(code)
      true -> ctrl_name(code)
    end
  end

  defp ctrl_name(code) do
    case code do
      "enter" -> :enter
      other -> String.to_atom("ctrl_" <> other)
    end
  end

  @doc """
  The letters the keymap actually binds as single-character keys
  (e.g. y/n/e for the approval dialog, q for quit). Reads the bindings
  rather than hardcoding — the keymap is data.
  """
  @spec bound_letters(Enumerable.t()) :: [atom()]
  def bound_letters(keymap) do
    keymap
    |> Enum.flat_map(fn {_action, patterns} ->
      Enum.flat_map(patterns, fn
        %{key: k, mod: mod} when mod in [nil, :none] ->
          if letter_atom?(k), do: [k], else: []

        _ ->
          []
      end)
    end)
    |> Enum.uniq()
  end

  defp letter_atom?(k) when is_atom(k) do
    Regex.match?(~r/^[a-z]$/, Atom.to_string(k))
  end

  defp letter_atom?(_), do: false

  # -- classification helpers ------------------------------------------------

  defp special?(code), do: Map.has_key?(@modmap, code)

  # Only single lowercase letters can be control candidates; interned
  # once via to_atom (bounded by the keymap, not by typing).
  defp single_lowercase?(code) do
    is_binary(code) and Regex.match?(~r/^[a-z]$/, code)
  end
end
