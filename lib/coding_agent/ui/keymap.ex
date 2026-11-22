# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.Keymap do
  alias CodingAgent.Core.UserConfig
  alias CodingAgent.UI.Bridge

  @moduledoc """
  Input keymap as DATA (ADR 011): action => [event patterns], defaults
  in code, overridable from ~/.config/coding-agent/ui.toml.

  A binding pattern matches a key event with the given key atom and
  modifier state. Patterns are maps with :key plus optional :mod — the
  event's key atom (e.g. :enter, :ctrl_a) and the modifier marker
  (`:none | :alt | :ctrl | :shift`) produced by
  `CodingAgent.UI.Bridge` from the terminal's own modifier list
  (crossterm reports modifiers; no ESC-prefix decoding is needed).
  """

  @typedoc "One concrete key event as produced by the bridge layer."
  @type event :: %{key: atom(), mod: :none | :alt | :ctrl | :shift}

  @typedoc "A match pattern; a missing :mod means :none."
  @type pattern :: %{key: atom(), mod: :none | :alt | :ctrl | :shift | :any}

  @typedoc """
  The actions the UI recognizes.

  The editing actions (`:insert_newline`, `:backspace`, `:delete`,
  `:cursor_*`, `:kill_*`) are performed by `CodingAgent.UI.Editor` — the
  one executor (ADR 021). They are keymap actions so a user can rebind
  them and so the action-coverage tripwire forces each to an owner.
  """
  @type action ::
          :send_input
          | :insert_newline
          | :backspace
          | :delete
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
          | :switch_agent
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
      # shift+enter is the common "newline" reflex from other tools; it
      # is explicit here so a terminal that REPORTS shift (kitty/meta
      # protocol) gets newline, matching composition-first (ADR 011).
      # Legacy terminals send the same bytes as alt+enter (ESC CR), so
      # there shift+enter IS send — the wire cannot tell them apart.
      insert_newline: [key(:enter), key(:enter, :shift), key(:ctrl_j)],
      # editing actions, performed by UI.Editor (ADR 021). Named (not
      # left unbound) so each has exactly one owner and the coverage
      # tripwire sees them.
      backspace: [key(:backspace)],
      delete: [key(:delete)],
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
      # synthesized ctrl_ names for ctrl chords: :ctrl_t, mod :none.
      toggle_tool_output: [key(:ctrl_t)],
      # switch the primary agent for the NEXT turn (ADR 018): Tab. A turn
      # in flight keeps its agent; Tab only changes what the next input
      # starts with.
      switch_agent: [key(:tab)],
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

  Modifier resolution is a **fallback lattice, most specific first**
  (review B, 2026-09-19): an exact modifier match wins, then a
  weak-modifier fallback, then `:any`. `:shift` is the weak modifier —
  terminals fold it into the character for letters and report it
  inconsistently for specials, so a shifted special with no explicit
  binding falls back to its unmodified binding. `:alt`/`:ctrl` are
  deliberate chords and match exactly (no fallback). The fallback is
  resolved BEFORE override order, so an exact `shift+X` binding can never
  lose to a plain `X` binding in an earlier action.

  Rationale: before this, mapping every shifted special to `:shift`
  (B2) silently unbound `shift+tab`, `shift+page_up`, `shift+page_down`,
  which had worked as their plain keys. A modifier family must not be
  able to unbind the unmodified bindings.
  """
  @spec resolve(t(), event()) :: action() | :unbound
  def resolve(keymap, %{key: k, mod: mod} = _event) do
    mods = candidate_mods(mod || :none)

    Enum.find_value(mods, :unbound, fn wanted_mod ->
      find_action(keymap, k, wanted_mod)
    end)
  end

  # The modifier candidates for an event, in priority order. `:any`
  # (wildcard) is always last.
  defp candidate_mods(:shift), do: [:shift, :none, :any]
  defp candidate_mods(:none), do: [:none, :any]
  defp candidate_mods(:alt), do: [:alt, :any]
  defp candidate_mods(:ctrl), do: [:ctrl, :any]
  defp candidate_mods(_), do: [:none, :any]

  # One pass over the actions for an exact key+modifier match, user
  # overrides first (their whole point). Pattern mod is normalized to
  # :none at construction (key/2), so this is an exact comparison.
  defp find_action(keymap, key, wanted_mod) do
    overridden = Map.get(keymap, :__overridden, [])

    try_pairs =
      Enum.map(overridden, fn a -> {a, Map.fetch!(keymap, a)} end) ++
        Enum.reject(keymap, fn {a, _} -> a in overridden or a == :__overridden end)

    Enum.find_value(try_pairs, fn {action, patterns} ->
      if Enum.any?(patterns, &match_pattern?(&1, key, wanted_mod)), do: action
    end)
  end

  defp match_pattern?(%{key: key, mod: mod}, key, wanted_mod), do: mod == wanted_mod
  defp match_pattern?(_, _, _), do: false

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
        # Validate against the existing action vocabulary WITHOUT minting
        # an atom from user text (review F1): the valid atoms are exactly
        # the defaults' keys and all exist once this module is loaded, so
        # to_existing_atom succeeds for them and rescues for the rest.
        action =
          try do
            String.to_existing_atom(String.replace(action_name, "-", "_"))
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
  # (ctrl is accepted in specs even though the terminals rarely deliver it).
  # Unknown key names resolve to `nil` and are DROPPED: a name the bridge
  # can never emit has no matching pattern, so it contributes nothing
  # rather than collapsing every unknown onto one atom (review F1).
  defp parse_spec(spec) do
    spec
    |> String.split(",")
    |> Enum.map(&to_pattern/1)
    |> Enum.reject(&is_nil/1)
  end

  # Every key name in a spec is resolved against the bounded bridge
  # vocabulary (`Bridge.key_atom/1`), which mints no atom from user text
  # and yields `:unknown_key` outside the set (review F1). An unknown key
  # can never match a real keypress, so dropping it is behavior-preserving.
  defp known_pattern(name, mod) do
    case Bridge.key_atom(name) do
      :unknown_key -> nil
      key -> %{key: key, mod: mod}
    end
  end

  defp to_pattern("alt-" <> k), do: known_pattern(k, :alt)

  # shift is a real event modifier now (kitty/meta protocol reports it);
  # only special keys keep it — a shifted letter arrives as its uppercase
  # char, not as a modifier.
  defp to_pattern("shift-" <> k), do: known_pattern(k, :shift)

  # Termbox names ctrl-chords distinctly (ctrl_a, ctrl_j, ...), so a
  # "ctrl-x" spec becomes the synthesized ctrl_ key name with mod :none —
  # the modifier is IN the key name. The one special case is ctrl-enter:
  # crossterm reports 0x0D with a ctrl modifier, kept as the
  # kitty-protocol hook (ADR 011).
  defp to_pattern("ctrl-enter"), do: %{key: :enter, mod: :ctrl}

  defp to_pattern("ctrl-" <> k), do: known_pattern("ctrl_" <> k, :none)
  defp to_pattern(k), do: known_pattern(k, :none)
end
