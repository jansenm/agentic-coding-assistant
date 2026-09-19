:orphan:

TUI backend: ex_ratatui
=======================

.. adr::
   :id: 012
   :status: Accepted
   :date: 2026-09-05
   :tags: stack, ui, tui

Context
-------

ADR 004 chose a hand-rolled TUI with ``ex_termbox`` as backend
(amendment, 2026-08-29); ADR 006 built the input-line concept on
termbox events. Phase 5 (terminal experience) made both concrete — and
concrete evaluation overturned the backend choice:

- ``ex_termbox`` 1.0.2 does not build: the vendored termbox compiles
  via waf (2018), which requires the Python ``imp`` module (removed in
  3.12+) and a ``python`` binary that modern systems no longer ship.
  Bending the build environment to appease a frozen 2020 C dependency
  in a *new* project was judged wrong.
- The phase-5 feature list (menus for agent/session selection,
  tab/window panes for sub-agent outputs, status line, sidebar with
  context/spend metrics, dialogs for agent questions) is all *layer*
  work; a cell-buffer library only helps at the bottom. Hand-rolling
  ANSI input parsing + rendering would still consume the hard 20%.
- Re-checking candidates: Ratatouille is still frozen (2020). Raxol
  2.6.1 is active but now carries 25 **non-optional** dependencies
  including Phoenix, LiveView and Cowboy — a stronger ADR 002 conflict
  than when rejected.
- **New candidate since ADR 004**: ``ex_ratatui`` — Elixir bindings
  for the Rust ratatui library via precompiled Rustler NIFs (first
  release Feb 2026, now 0.13.1).

Verified facts (Sept 2026):

- ``ex_ratatui``: MIT, **zero hex dependencies**, 13 releases in 6.5
  months (very active), headless test backend with event injection,
  Elm-style reducer or LiveView-style runtimes, OTP-supervised,
  bracketed-paste/mouse/resize/focus events, DirtyIo event polling.
- The maturity stack is inverted relative to termbox: the *bindings*
  are young (one maintainer, fast API drift — 13 minors in 6.5
  months), but the Rust core is heavily battle-tested: ratatui 0.30
  (48.8M crates.io downloads, since 2023, successor of tui-rs) on
  crossterm 0.29 (185M downloads, since 2018). The churny part is the
  thinnest, most predictable layer.
- Feature coverage for the phase-5 list: List/Tabs/Table menus,
  constraint-based layout splits (sub-agent panes), TextInput/
  Textarea (ADR 011 input, including multi-line paste — the CLI
  paste-queue desync has no TUI counterpart), focus management with
  tab cycling and mouse hit-testing, Markdown/CodeBlock widgets for
  agent output, Gauge/Chart for a context/spend sidebar. Precompiled
  NIFs cover Linux x86_64/aarch64 and OTP 26-29 (this project: OTP 28,
  ABI 2.17) with no Rust toolchain; source builds need Rust but are
  opt-in.

Decision
--------

**Adopt ``ex_ratatui`` as the TUI backend**, superseding the termbox
amendment in ADR 004/006. ADR 004's core decision — hand-rolled *UI
components* over a small terminal backend, with the UI as a thin driver
over ``CodingAgent.Core`` — is unchanged; only the backend moves.

Risk posture, stated explicitly: the project is young with one
maintainer and a drifting Elixir API. Mitigations: pin the version
tightly; keep ``CodingAgent.UI`` as the containment boundary so a
future backend swap touches only UI code; keep ADR 011's keymap
binding-agnostic (it maps *actions*, not event sources); adopt the
headless backend + event injection for tests so UI behavior is
verifiable without a terminal, in CI, as our test discipline demands.

Consequences
------------

- No C build step, no Python/waf; the dependency tree stays pure-Elixir
  plus one precompiled NIF (ADR 002's dependency-minimality holds; the
  NIF is audited at the API boundary, like any precompiled artifact —
  documented residual trust).
- The low-level layer the owner did not want to hand-roll (escape
  sequences, diff rendering, layout, paste) is provided; our code
  stays at the application layer: keymap (ADR 011), session driver,
  approval flow, panes.
- Multi-line paste and alt/ctrl-modifier reporting arrive via
  crossterm's input stack. ADR 011's ESC-prefix decoder is therefore
  unnecessary — crossterm reports modifiers natively — and was
  **deleted** (2026-09-19): it had no call site, and the CLI line mode
  uses ``IO.gets``, which never needed it. The earlier "kept for the
  CLI line-mode harness" justification was false.
- API drift is a real maintenance cost: version bumps will occasionally
  touch UI code. Accepted in exchange for not owning the bottom layer.
- Future surfaces (SSH/distributed attach, LiveView embedding) are
  transports of the same app module, not new frontends.