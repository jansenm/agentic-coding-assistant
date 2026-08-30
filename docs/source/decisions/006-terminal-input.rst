:orphan:

Terminal input line on ex_termbox
=================================

.. adr::
   :id: 006
   :status: Accepted
   :date: 2026-08-29
   :tags: stack, ui, tui

Context
-------

ADR 004 chose a hand-rolled TUI and named ``ex_termbox`` as a possible
backend. The input experience should offer standard readline-style
editing (ctrl-a/ctrl-e line jumps, word killing, history) without
hand-rolling the low-level terminal handling.

Verified facts:

- **ex_termbox delivers the key events needed**: ``ctrl_a``/``ctrl_e``
  are distinct key constants; arrows, home/end and alt-chords are
  available. The termbox C library parses terminal escape sequences into
  key events — the grungy layer is covered.
- **ex_termbox does not provide an editable input field.** It renders
  cells and emits events; cursor movement, a text buffer and editing
  bindings are application-level components.
- Dependency profile: zero runtime Elixir dependencies, one C submodule
  (``nsf/termbox``, ~2k stars, stable, small), compiled via
  ``elixir_make``. In line with ADR 002.

Decision
--------

**ex_termbox** is the terminal backend (input events + cell rendering).
On top of it, a small **input-line component** is implemented in plain
Elixir: text buffer, cursor position, readline-style bindings
(ctrl-a/e, ctrl-k/w/u, arrows, history), rendering as termbox cells.

Consequences
------------

- The editing bindings are our code (~200–300 lines), but pure
  state-transition logic: buffer + key event → buffer + cursor, trivially
  unit-testable.
- No readline/line-editor dependency enters the tree; the component is
  reusable for approval prompts and search later.