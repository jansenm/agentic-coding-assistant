defmodule CodingAgent.UI.Keymap do
  alias CodingAgent.Core.UserConfig

  @moduledoc """
  Input keymap as DATA (ADR 011): action => [event patterns], defaults
  in code, overridable from ~/.config/coding-agent/ui.toml.

  A binding pattern matches an `ExTermbox.Event` of type :key with the
  given key and modifier state. Patterns are maps with :key plus
  optional :mod — the event's key atom (e.g. :enter, :ctrl_a) and a
  modifier marker (:alt | :none) produced by the ESC-prefix decoder
  (CodingAgent.UI.AltDecode).
  """

  @typedoc "One concrete key event as produced by the decoder layer."
  @type event :: %{key: atom(), mod: :none | :alt}

  @typedoc "A match pattern; a missing :mod means :none."
  @type pattern :: %{key: atom(), mod: :none | :alt | :any}

  @typedoc "The actions the UI recognizes."
  @type action ::
          :send_input
          | :insert_newline
          | :cursor_home
          | :cursor_end
          | :cursor_left
          | :cursor_right
          | :cursor_up
          | :cursor_down
          | :kill_to_end
          | :kill_word
          | :kill_line
          | :history_prev
          | :history_next
          | :scroll_up
          | :scroll_down
          | :toggle_tool_output
          | :approve
          | :edit
          | :reject
          | :abort

  @typedoc "action => [patterns]. Overridden actions are ALSO listed in
  :__overridden (insertion order); resolution consults overridden
  actions first so a user binding wins over a default on the same key."
  @type t :: %{action() => [pattern()], optional(:__overridden) => [action()]}

  @doc "Default keymap per ADR 011: composition-first (enter=newline)."
  @spec defaults() :: t()
  def defaults do
    %{
      send_input: [key(:enter, :alt), key(:enter, :ctrl)],
      insert_newline: [key(:enter), key(:ctrl_j)],
      cursor_home: [key(:ctrl_a), key(:home)],
      cursor_end: [key(:ctrl_e), key(:end)],
      cursor_left: [key(:ctrl_b), key(:arrow_left)],
      cursor_right: [key(:ctrl_f), key(:arrow_right)],
      cursor_up: [key(:arrow_up)],
      cursor_down: [key(:arrow_down)],
      kill_to_end: [key(:ctrl_k)],
      kill_word: [key(:ctrl_w)],
      kill_line: [key(:ctrl_u)],
      history_prev: [key(:ctrl_p), key(:arrow_up, :ctrl)],
      history_next: [key(:ctrl_n), key(:arrow_down, :ctrl)],
      scroll_up: [key(:page_up)],
      scroll_down: [key(:page_down)],
      # tool-output toggle: ctrl-t ('t' must stay free for text input;
      # found live — the owner types t in messages). The bridge emits
      # termbox names for ctrl chords: :ctrl_t, mod :none.
      toggle_tool_output: [key(:ctrl_t)],
      # interrupt the running turn: while a turn is in flight esc is a
      # DOUBLE press (a lone esc is pressed out of habit in text fields —
      # vim muscle memory); while idle esc is the double-press quit
      # confirm. Esc closes popups first (handled before keymap
      # resolution in the TUI). Crossterm decodes Esc as "esc"
      # (events.rs:78); accept both spellings.
      interrupt: [key(:esc)],
      abort: [key(:ctrl_c)]
    }
  end

  defp key(k, mod \\ :none), do: %{key: k, mod: mod}

  @doc """
  Resolves an event against a keymap: the action atom, or :unbound when
  nothing matches.
  """
  @spec resolve(t(), event()) :: action() | :unbound
  def resolve(keymap, %{key: k, mod: mod} = _event) do
    event = %{key: k, mod: mod || :none}

    overridden = Map.get(keymap, :__overridden, [])

    # user overrides first (their whole point), then the rest
    try_pairs =
      Enum.map(overridden, fn a -> {a, Map.fetch!(keymap, a)} end) ++
        Enum.reject(keymap, fn {a, _} -> a in overridden or a == :__overridden end)

    Enum.find_value(try_pairs, :unbound, fn {action, patterns} ->
      if Enum.any?(patterns, &matches?(&1, event)) do
        action
      end
    end)
  end

  # Pattern semantics (ADR 011): a pattern matches when the keys are
  # equal AND the modifier matches exactly — except :any, which matches
  # every modifier. A pattern without :mod is normalized to :none at
  # construction (key/2 in defaults), so this stays exact.
  defp matches?(%{key: key, mod: mod}, %{key: key, mod: mod}), do: true
  defp matches?(%{key: key, mod: :any}, %{key: key, mod: _}), do: true
  defp matches?(_, _), do: false

  @doc """
  The effective keymap: defaults merged with the user's ui.toml
  `[keys]` overrides (global ~/.config/coding-agent/ui.toml and the
  project's .coding-agent/ui.toml — ADR 014). Unknown actions are
  ignored. No cache: the files are tiny, sessions load once at mount
  (call sites hold the result).
  """
  def load do
    # a broken user TOML must never take down a live TUI mid-keypress:
    # degrade to the defaults (a startup check surfaces the parse error
    # loudly enough; the TUI just keeps its built-in keys)
    user_keys =
      case UserConfig.load_safe(nil) do
        {:ok, cfg} -> cfg.ui["keys"] || %{}
        {:error, _reason} -> %{}
      end

    {merged, _unknown} = merge(defaults(), user_keys)
    merged
  end

  @doc """
  Merges user overrides (from ui.toml `[keys]`) over the defaults.
  Values are action-name => key-spec strings, e.g.:
  `send_input = "alt-enter"` or `insert_newline = "ctrl-j,enter"`.
  Unknown actions are ignored with a warning list returned alongside.
  """
  @spec merge(t(), %{String.t() => String.t()}) :: {t(), [String.t()]}
  def merge(keymap, overrides) when is_map(overrides) do
    {merged, unknown} =
      Enum.reduce(overrides, {keymap, []}, fn {action_name, spec}, {acc, unknown} ->
        action =
          try do
            # user config may name an action the atom table has never
            # seen — build the atom, then validate membership below
            String.to_atom(String.replace(action_name, "-", "_"))
          rescue
            ArgumentError -> :unknown_action
          end

        if Map.has_key?(acc, action) do
          prev_overridden = Map.get(acc, :__overridden, [])

          acc2 =
            acc
            |> Map.put(action, parse_spec(spec))
            |> Map.put(:__overridden, prev_overridden ++ [action])

          {acc2, unknown}
        else
          {acc, [action_name | unknown]}
        end
      end)

    {merged, Enum.reverse(unknown)}
  end

  # "alt-enter,ctrl-enter" -> [%{key: :enter, mod: :alt}, %{key: :enter, mod: :ctrl}]
  # (ctrl is accepted in specs even though the terminals rarely deliver it)
  defp parse_spec(spec) do
    spec
    |> String.split(",")
    |> Enum.map(&to_pattern/1)
  end

  defp to_pattern("alt-" <> k), do: %{key: String.to_existing_atom(k), mod: :alt}

  # Termbox names ctrl-chords distinctly (ctrl_a, ctrl_j, ...), so a
  # "ctrl-x" spec becomes the termbox key name with mod :none — the
  # modifier is IN the key name. The one special case is ctrl-enter:
  # termbox reports 0x0D as plain :enter, and a :ctrl modifier can
  # never actually arrive on legacy terminals — kept as the
  # kitty-protocol future hook (ADR 011).
  defp to_pattern("ctrl-enter"), do: %{key: :enter, mod: :ctrl}

  # synthetic ctrl_/alt_ atoms match the defaults() convention
  # (key(:ctrl_j) with mod :none); build safely — user config may
  # name a chord the atom table has never seen
  defp to_pattern("ctrl-" <> k), do: %{key: String.to_atom("ctrl_" <> k), mod: :none}
  defp to_pattern(k), do: %{key: String.to_atom(k), mod: :none}
end
