.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

Keymap and input defaults
=========================

.. adr::
   :id: 011
   :status: Accepted
   :date: 2026-09-05
   :tags: ui, tui, input, keymap

Context
-------

The terminal experience (phase 5) needs input keybindings. Two
opinions shaped the decision:

- The owner's default stance: **enter inserts a newline** in the input
  field — free composition of multi-line prompts is the primary mode.
  Sending is a deliberate act.
- Keybindings are taste; they must be **configurable**, not hardwired.

Verified facts (checked before deciding, not assumed):

- ``ex_termbox`` 1.0.2 (classic nsf/termbox) has **no modifier
  reporting**: no ``TB_ALT``/``TB_MOD`` constants in the vendored
  library. Alt arrives as ``ESC`` followed by the key code — two
  events, terminal-dependent.
- In the primary dev environment (tmux 3.7b, ``tmux-256color``),
  **ctrl-enter and shift-enter are indistinguishable from plain
  enter**: legacy mode collapses them to 0x0D, and terminfo carries no
  distinct ``kent``. They become real keys only via the kitty keyboard
  protocol passthrough (tmux 3.2+ and the outer terminal both opting
  in) — not something a default can rely on.
- Therefore **alt-enter is the only modifier-enter that survives
  ordinary terminals**, at the cost of an ESC-prefix decoder owned by
  our input layer.

Decision
--------

**Defaults** (composition-first):

- ``enter`` → insert a newline in the input buffer
- ``alt-enter`` → send the input to the agent

The ESC-prefix decoder (alt = ``ESC`` + key within a short window,
lone ``ESC`` stays escape) is a first-class component, implemented in
Elixir over termbox events — not assumed from the library.

**Pragmatic aliases** so both conventions work on day one without
changing the defaults:

- ``ctrl-j`` → insert newline (readline habit)
- ``shift-enter`` → insert newline, *when the terminal reports the
  shift modifier* (kitty/meta protocol). Shift is a real event
  modifier now (see the amendment below); on legacy terminals
  shift-enter sends the same bytes as alt-enter, so there it is
  indistinguishable from send. Alt-enter remains the dependable send
  key.
- ``ctrl-enter`` → send, *when the terminal can distinguish it*
  (kitty-protocol terminals); silently absent elsewhere.

.. note::
   **Amended 2026-09-19.** This table originally read
   ``ctrl-enter``/``shift-enter`` → **send**. The implementation now
   binds ``shift-enter`` → ``insert_newline`` (composition-first: the
   common "newline" reflex, matching plain enter), and ``Bridge``
   carries ``:shift`` as a first-class modifier through to ``Keymap``.
   The keymap is the data-of-record (this ADR's own claim), so the
   table follows the code. ``ctrl-enter`` remains the kitty-protocol
   send hook.

**The keymap is data from the first commit**: a map
``action => [key_event_patterns]`` with the defaults in code, overridable
from ``~/.config/coding-agent/ui.toml`` (a separate ``[keys]`` table).
The permission file (``.coding-agent/permissions.toml``) is security
policy and stays separate from taste.

Other v1 bindings follow ADR 006: ctrl-a/e/left/right/home/end cursor
motion, ctrl-k/w/u kills, arrow-key history, pgup/pgdn (plus mouse
wheel later) for transcript scrolling, ``ctrl-c`` abort, ``y``/``e``/``n``
at the approval widget. The session switcher (phase 5d) picks its
binding when it exists.

Consequences
------------

- Multi-line input is the primary mode: the ADR 006 input component is
  a *growing* multi-line buffer from day one, not a single-line field
  with escape tricks. The line-mode workarounds from dogfooding have
  no TUI counterpart to carry over.
- We own the ESC-prefix decoder (~30 lines + timing subtleties) —
  accepted cost; it is the price of alt-chords on classic termbox.
- Terminals without alt support degrade: enter/newline still works,
  send needs the configured alternative. The keymap being data makes
  every such adjustment a config edit, not a recompile.
- tmux users who want true ctrl/shift-enter can enable the kitty
  protocol passthrough; the keymap then accepts those patterns like
  any other.