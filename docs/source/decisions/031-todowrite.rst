:orphan:

The todowrite tool: a durable plan the model keeps visible
==========================================================

.. adr::
   :id: 031
   :status: Accepted
   :date: 2026-09-28
   :tags: sessions, agents, tools, prompts, ui

.. note::
   Accepted and implemented 2026-09-28. Answers T4 in the ``TODO.md``
   "rival opencode" list. Adds a ``todowrite`` tool: the model maintains
   a session-scoped todo list, the session owns the state and injects the
   current list into every request, and the TUI renders it as a fourth
   sidebar block. The plan agent finally has a durable artifact.

Context
-------

Multi-step work is the default in this harness, but the model's plan
lives only in the token stream. Three failures follow, all observed
while building and dogfooding:

1. **The plan scrolls away.** A turn that touches six files states its
   plan in prose, then the tool output that matters for step 4 buries the
   plan for step 5. The model re-derives it, or forgets it.
2. **Compaction eats it.** A long session is summarized; the plan was
   never a first-class thing, so it is summarized too — lossily. There is
   no object that says "these are the open items".
3. **The human cannot see it.** The user sees tool output, not intent.
   "What is this agent doing and how far along is it" has no answer until
   the turn ends.

The scope-creep incident that produced ADR 027 (a ``build`` turn grew
into a cross-cutting refactor, 772 lines) is the same gap seen from the
other side: the model had no durable place to say what it intended, so
"what I meant to do" and "what I have done" were the same undifferentiated
stream.

opencode ships ``todowrite`` for this. Its shape (from
``packages/opencode/src/tool/todowrite.ts``, MIT, 2026-09-28): the call
carries the **complete** list (``todos: [{content, status, priority?}]``),
the session stores it, and the UI renders the statuses. ADR 024 already
noted the consequence for prompts (Claude's variant uses "heavier todo
use"); this ADR makes the tool real.

Decision
--------

**1. A ``todowrite`` tool whose call carries the WHOLE list.**
``todos: [{content, status}]`` with ``status`` in
``pending | in_progress | completed``. The call REPLACES the stored list
(no add/remove/update verbs, no per-item ids): opencode's shape, and the
only one with no merge semantics to get wrong. The model is the single
writer; the session never edits the list on its own.

**2. The list is session state, persisted for free.**
A ``todos`` field on ``%State{}``, like ``usage``: the store's ``state``
BLOB already round-trips the struct, so there is no schema migration and
no new table. ``restore/1`` heals old snapshots (``Map.get(state,
:todos, [])``) and ``resume_opts/2`` carries it forward. Todos are
durable across a restart and a resume.

**3. The session intercepts the call, like ``question``/``task``.**
``todowrite`` does not run a callback (the callback is a loud safety net).
``Session.execute_round/3`` splits its calls out before the gate, writes
``state.todos``, and returns a short result ("Updated 5 todos"). Three
properties follow:

  - **No pause.** Unlike ``question``, a todo update never parks the
    session — the model calls it every few steps. It folds into the round
    like any auto-executed call.
  - **No gate.** The tool is registered in the read-only class (like
    ``question``): it writes no file, spends no reach, and every agent —
    including the ``plan`` agent and a subagent — carries it. A child
    session keeps its own ``todos``; there is no fan-in to the parent.
  - **One result per call.** ``complete_round/3``'s invariant (every call
    has exactly one result, declared by one assistant message) is
    unchanged.

**4. The current list is injected per request, not stored as messages.**
``wire_request/1`` appends a current-todo block to the system message
through ``Prompt.with_todos/2``, the same per-call channel ADR 024
established for the environment block (the stored context is untouched).
This is what survives compaction: the list is not an old message that can
be summarized away, it is re-derived from live state on every call. It
also matches the tool's full-replace semantics — the model always sees
the list it is about to replace.

The block is omitted when the list is empty, so a session that never uses
todos sends nothing new.

**5. The UI is a fourth sidebar block.** The sidebar is ADR 018's home
for always-visible session facts, so the todo list goes there: one row
per item, a status glyph (``✔`` completed, ``▸`` in progress, ``·``
pending) and the content, truncated to the panel width; a long list is
capped with ``… +N more`` so the panel height stays bounded. The TUI
mirrors the list from ``{:todos_updated, todos}`` (broadcast with the
tool result) and seeds it from ``Session.state/1`` on mount, exactly as
``session_usage`` and ``session_effort`` are seeded.

**6. An item may carry agent-private ``notes`` (amendment, 2026-09-30).**
Each item optionally takes ``notes``: durable facts the model wants to
keep — exact paths, test counts, decisions and why, measured numbers. It
is the place to externalize knowledge that would otherwise sit in old
messages that compaction can summarize away. Two deliberate properties:

  - **Notes are NOT shown in the sidebar.** The panel is the human's view
    of *intent and progress* (a checklist); notes are the model's private
    working memory. Rendering them would turn the panel into a log and let
    a private channel drift into the human-facing one. To read them back
    for a post-mortem, inspect the live session with ``Session.state/1``
    (or the stored state); they are not in the export or the display view.
  - **Notes DO ride the injected block.** ``Prompt.todos_block/1`` renders
    them as an indented sub-line under their item, so the model reads them
    back on every request and compaction cannot eat them — the same
    survival property the list itself relies on (decision 4).

Because notes ride every request, they are bounded: ``@max_notes_chars``
(500) per item and ``@max_notes_total_chars`` (4000) across the list, or
the block would bloat the system prompt. Notes are kept as-is (not
flattened to one line, unlike ``content``) — they never reach the
sidebar's row math, so line breaks are useful structure.

Consequences
------------

- The plan is durable and visible: the model reads it back every request,
  the human reads it in the sidebar, compaction cannot eat it.
- ``todowrite`` is cheap: pure state, no process, no filesystem, no gate.
- The full-replace contract is token-heavier than incremental updates for
  a long list, and the model can drop an item by omitting it — accepted,
  because the alternative (merge verbs) is where the bugs live. The tool
  description states the contract plainly.
- The tool is available to every agent including the ``plan`` agent; a
  subagent's list is its own. Whether a parent should ever see a child's
  list is left to the subagent work (unlike ``question``, there is no
  ADR 017 "may not ask a primary" analogue — a child simply keeps its
  own).
- The status glyphs/roles live in the UI; the model is told the three
  statuses, not the glyphs.

Open questions
--------------

1. **Should a completed turn auto-clear the list?** opencode leaves it to
   the model. Auto-clearing would hide a plan the human is still reading;
   not clearing means a stale list can linger. Start by leaving it to the
   model (it can send ``[]``).
2. **Should the sidebar show todos only while non-empty, or always?** The
   first shape hides the block until the first ``todowrite``, so a
   session that never plans gains no chrome.
3. **Per-agent lists (ADR 017).** A plan agent's list and a build agent's
   list are distinct today (per session). If agent switching should carry
   the list across, that is a later decision.
