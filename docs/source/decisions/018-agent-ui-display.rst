:orphan:

UI: running vs. next agent, and subagent views
==============================================

.. adr::
   :id: 018
   :status: Proposed
   :date: 2026-09-17
   :tags: ui, agents, subagent, tui

.. note::
   Proposed 2026-09-17. The two-slot display and the next-agent switch
   can ship with ADR 017. Subagent **views** need the ``task`` seam
   (the slice after ADR 017) and are specified here so that seam is
   built with the UI contract in mind, not retrofitted.

Context
-------

ADR 017 introduced agent definitions and the primary/subagent
distinction. Two UI requirements follow, and one existing limitation:

1. The UI must show **two agents at once**: the one *currently running*
   a turn, and the one the *next* input will start with. Each with its
   **model**, because a definition may set its own (ADR 017) and the two
   can differ.
2. Subagents are **currently invisible**. The TUI subscribes to exactly
   one channel — ``{:session_events, parent_id}`` — and every session
   broadcasts on ``{:session_events, state.id}``
   (``Session.broadcast/2``). A child session has its own id, so its
   events reach no subscriber. Nothing appears while a subagent works.
3. Mixing child events into the parent transcript is **not** acceptable:
   it would be unreadable, and it risks the ADR 007 rule-3 invariant
   (the parent model sees summaries, never subagent transcripts).

The owner's direction (from opencode): **a tab per running subagent**,
reachable by a key binding — you can open a subagent's log, but it is
never blended into the parent view. Subagents always produce a summary;
the parent turns that summary into its result.

Decision
--------

Three parts: a two-slot header, a tab model for subagents, and one
invariant enforced at the context boundary.

### 1. Two slots: running and next

The sidebar (or status area) carries two labelled slots:

- **running** — the agent executing the *active* turn. With no subagent
  this is the primary; while a subagent runs it is that subagent (the
  leaf of the active delegation). Shown with its model.
- **next** — the agent the next input will start with: the primary,
  switchable by **Tab**. Shown with the model a new request would use
  (the definition's ``model`` when it sets one, else the session model).

The slots are distinct because a run in flight keeps the agent it
started with; switching Tab mid-run changes only the *next* turn. This
is already true for primaries and will hold for delegation.

### 2. Subagent tabs

- The **primary tab** is the main transcript (today's view).
- Each running subagent gets its **own tab** with its own transcript
  (its streamed reasoning/answer, its tool calls). Tabs are ephemeral:
  a finished subagent's tab closes (the parent result remains the
  record), matching the "ephemeral child" model of ADR 017.
- **Navigation** is by key binding, deliberately not Tab (Tab switches
  the primary). The exact chords are an implementation question below;
  the shape is next/previous-tab plus a jump-to-subagent.
- The header's **running** slot names which tab is the live leaf.

### 3. The invariant: visibility is not context

Subagent transcripts are visible in the UI and **never** enter the
parent model context. This is enforced **where the context is built**
(the session), not in the view: a subagent's only contribution to the
parent context is its **summary**, wrapped as the ``task`` tool result.
Child events are broadcast for the UI on a channel the parent context
code path never reads.

Concretely, the contract for the ``task`` slice:

- The parent session broadcasts ``{:subagent_started, child_id,
  agent_name}`` and ``{:subagent_finished, child_id, outcome}`` on its
  **own** channel.
- The TUI, already subscribed to the parent, learns child ids from those
  events and temporarily subscribes to ``{:session_events, child_id}``
  for the tab. It unsubscribes when the child finishes.
- The child runs the standard loop with its own isolated context
  (ADR 017). Its system prompt is the definition body; it is instructed
  to **return a summary**. The parent appends exactly that summary —
  never the child transcript — as the tool result.

This keeps event routing simple (the TUI tracks ids; the session owns
context) and puts the rule-3 invariant at the one boundary that matters.

Consequences
------------

- The UI answers "what is happening now" and "what happens if I type"
  without ambiguity, with the model in both.
- Subagents are debuggable (open their tab) without polluting the parent
  context or the parent transcript.
- The two-slot part is implementable immediately after ADR 017; the tab
  part lands with the ``task`` seam and is specified now so the seam
  emits the events the UI needs.

Open questions for the implementation slice
-------------------------------------------

1. **Subagent navigation keys.** Tab is taken (primary switch). Candidates:
   ``ctrl-x`` menu items ("next subagent", "previous subagent"), or
   ``ctrl-←/→`` / ``alt-←/→``. Needs a binding that does not collide
   with text editing or the existing arrow history bindings.
2. **Many subagents.** A key per subagent does not scale; the tab model
   needs a bounded tab bar (e.g. show N, cycle through the rest) or a
   picker. Decide when parallelism is actually used.
3. **Where the two slots live:** sidebar (it is already the "agent"
   panel) versus the status line (always visible, one row). The sidebar
   has room for both with models; the status line is at a premium.
   **Answered 2026-09-23** (amendment below): neither — the running slot
   gets its own row above the input (the live band), the sidebar keeps
   the badges, and the composer's row below the field is setup only.
4. **Finished subagent detail.** Keep the last subagent's tab until the
   next delegation (easier to read), or close immediately (matches
   ephemeral semantics). Lean "keep until replaced", read-only.

Amendment 2026-09-23: the running/next split gets its own row
-------------------------------------------------------------

**Status: Accepted (amendment to the Proposed ADR 018; part 1 shipped).**

Open question 3 above is now answered, and the answer is "neither of the
two options offered": the two slots do **not** share a row. The
sidebar-versus-status-line choice assumed that one row can carry both
facts. It cannot, and the reason is the ADR's own point 1 — the two can
differ.

**What was measured.** After implementation the composer's meta row (the
row below the input field) carried the *next* agent and model on its left
half and the *running* turn's status on its right half. Idle, both slots
name the same agent, so the row read correctly. After ``tab`` with a turn
in flight (measured 100×30: ``running=build``, ``next=plan``), the row
read ``build · model …   ⠋ thinking`` — one row, two subjects, and the
status looked like it belonged to ``plan``. The row never *stated* the
running agent, so nothing was wrong in the data; the layout made one row
answer two questions, and the reader cannot tell which half belongs to
which.

**Decision (owner): three rows with distinct jobs.**

- The **live band** (``CodingAgent.UI.LiveBand``), a permanent row
  **above** the input field, answers "what is the RUNNING turn doing": the
  running agent and model (only while a turn is in flight — idle, the row
  below already names them) plus the status glyph, word and elapsed
  context. It paints on the ``base`` surface, the transcript's own
  background, so it reads as part of the reading area and is
  distinguishable from the input field by background alone. One cell of
  padding on all four sides.
- The composer's **meta row**, below the field, is **setup only**: the
  agent and model the *next* input will use — the ones ``tab`` and the
  model menu change. It no longer receives a status at all (the struct
  field is gone, so a caller cannot pass one).
- The **sidebar** keeps the badges it already has (``build running`` /
  ``plan next`` while busy, the next agent when idle). It is the
  always-visible panel; the band is the one that sits next to the input.

The status is drawn in exactly one place: ``Styles.status_line/6`` is the
single composition of glyph, word and elapsed, and ``UI.LiveBand`` is its
only caller. The band chooses the *label* it passes (``running mix`` for a
tool in flight, ``thinking`` for a silent busy turn, ``nil`` for the
badge's own word); the wording, the spinner frames and the colour roles
cannot fork.

**The elapsed context is gated on ``busy?``.** The composer's status line
used to count seconds only while a turn was busy; the band must keep that
rule or a finished turn reads ``○ idle · 204s`` — a frozen count beside a
non-running state. The same gate keeps a tool left "in flight" by a failed
turn (the result that would clear it never arrives) from labelling the
next pause ``running mix``; a non-busy status transition drops the
in-flight tool as hygiene.

**Consequence for ADR 018 part 2 (subagent tabs).** The band is where a
subagent's running identity will surface: when the ``task`` seam lands,
the running slot names the leaf of the active delegation, and the band is
the row that shows it without touching the next-input setup. The band's
identity prefix is therefore deliberately "the running agent, whoever that
is" — not "the primary".

**Consequence for overlays (found while implementing).** Every overlay
(menu, approval, budget, doom, question) now places against the room
*above* the band, and its height is clamped to that same room — one
``overlay_room/2`` for both numbers. The previous pair of fixed offsets
(``area.height - 4`` for the menu cap, ``area.height - h - 3`` for the
placement) only worked while the row they must not cover was the
composer's own meta row; with a 26-row popup on a 30-row window the
placement went negative and the frame was dropped with
``rect.y: unexpected value``. A dialog that hides the band hides the very
status it asks about.

Acceptance: ``test/coding_agent/ui/live_band_test.exs`` (row composition
as a unit), ``track_b_status_test.exs`` ("the live band (A)": the band
carries the running identity and the status, the setup row carries
neither, ``tab`` moves only the setup row), ``tui_cells_test.exs`` (the
band's ``base`` background and its four-sided padding, plus the
``last_pane_height`` arithmetic that proves measure = paint), and
``tui_visual_test.exs`` (an approval dialog ends above the band).
