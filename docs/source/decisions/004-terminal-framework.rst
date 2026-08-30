:orphan:

Terminal UI framework
=====================

.. adr::
   :id: 004
   :status: Accepted
   :date: 2026-08-29
   :tags: stack, ui, tui

Context
-------

The assistant's primary interface is a terminal UI (see
:doc:`002-elixir-beam`). The opencode terminal interface is considered
sufficient as a UX target. Candidates:

- **Raxol** — ambitious multi-surface runtime (terminal, LiveView, SSH),
  very active (daily commits), 30+ widgets, AI-agent runtime built in.
  But: the umbrella mix.exs pulls ~55 dependencies (Phoenix, Ecto, Nx)
  with several precompiled NIFs into a *terminal* app's tree, and the
  community is small (76 stars, single-digit weekly organic downloads).
  This conflicts with the dependency-minimality constraint of
  :doc:`002-elixir-beam`.
- **Ratatouille** — the "usual choice" by stars (849) and lifetime
  downloads (~14k), but effectively **unmaintained**: last release March
  2020, last commit October 2021, zero commits since 2024. Adoption
  detects attacks only when somebody keeps the code alive; an abandoned
  dependency concentrates risk rather than spreading it.
- **Hand-rolled TUI** — direct ANSI/terminal handling, optionally on the
  tiny ``ex_termbox`` backend (2 C-file surrogate lib, MIT, last release
  2020 but its surface — raw input + cell buffer — is stable and small).
  Maximum auditability, moderate implementation cost.

Adoption as a security heuristic was part of the evaluation: the more a
library is used, the faster defects and attacks are found. That heuristic
favors large communities and active maintenance over name recognition.

Decision
--------

**Hand-roll the terminal UI**, keeping its conceptual dependencies small:

- ANSI escape sequences for rendering (alt-screen, cursor, colors),
- raw-mode input handling,
- a diff-updated cell/screen buffer,
- terminal resize handling.

The standard agent TUI surface is deliberately minimal — one scrollable
transcript pane, one input line, one status/approval line — so a widget
framework's value is marginal for this project.

*Amendment (2026-08-29):* the backend decision was subsequently made —
``ex_termbox`` covers input events and cell rendering (ADR 006), so the
raw-handling bullets above are provided by termbox rather than
hand-written ANSI code. The rendering/editing components above it remain
hand-rolled (see :doc:`006-terminal-input`).

The UI layer is a thin *driver* over the agent core (see
:doc:`../explanation/overview`), keeping future surfaces — e.g. a
LiveView or browser terminal — decisions of their own rather than
consequences of this one.

Consequences
------------

- The dependency tree stays minimal and pure Elixir; the terminal layer
  is our code and auditable by definition.
- We own terminal edge cases (resize, cursor, redraw, latency) — accepted
  cost, bounded by the small widget count.
- If the hand-rolled layer proves unmanageable, Ratatouille (familiar,
  frozen, small) is the documented fallback for a *read-only* transcript
  UI; Raxol remains a documented non-choice because of its dependency
  profile.