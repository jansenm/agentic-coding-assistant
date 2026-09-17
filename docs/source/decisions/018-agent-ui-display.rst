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
4. **Finished subagent detail.** Keep the last subagent's tab until the
   next delegation (easier to read), or close immediately (matches
   ephemeral semantics). Lean "keep until replaced", read-only.
