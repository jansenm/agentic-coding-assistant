:orphan:

UI: running vs. next agent, and subagent views
==============================================

.. adr::
   :id: 018
   :status: Accepted
   :date: 2026-09-17
   :tags: ui, agents, subagent, tui

.. note::
   Accepted 2026-10-01 (status was stale at ``Proposed``; both parts and
   the tab shipped — see below). Proposed 2026-09-17. The two-slot
   display and the next-agent switch
   can ship with ADR 017. Subagent **views** need the ``task`` seam
   (the slice after ADR 017) and are specified here so that seam is
   built with the UI contract in mind, not retrofitted.

   **Part 1 shipped** (two slots / the live band — see the amendment
   below). **Part 2 (the ``task`` seam) shipped 2026-09-25**: the child
   session, the parent events (``{:subagent_started, child_id, name,
   model}`` / ``{:subagent_finished, child_id, outcome}``), the
   summary-only return, the depth-1 bound, and the live band naming the
   leaf of the active delegation. **The subagent TAB shipped in
   amendment (ii)** (2026-09-25): the tagged wire, the in-memory child
   tabs, the bounded tab bar and ``ctrl-x a``.

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
   **Refined 2026-09-25** (the sidebar amendment lower down): the sidebar
   keeps the running/next SPLIT, but as definition rows in its identity
   block, not as badges — the panel was regrouped and the badge shape
   went with it.
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
- The **sidebar** keeps the running/next **split** (``build running`` /
  ``plan next`` while busy, the next agent when idle) as rows of its
  identity block — the badge *shape* was replaced by definition rows in
  the 2026-09-25 sidebar amendment; the split itself is unchanged. It is
  the always-visible panel; the band is the one that sits next to the
  input.

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

Amendment 2026-09-25: the ``task`` seam ships (part 2, without the tab)
-----------------------------------------------------------------------

**Status: the delegation mechanics and the band's leaf identity are
implemented. The subagent TAB (open a child's transcript) is not.**

The seam, end to end:

- **The tool.** ``Core.Tools.Task`` is a ``task`` tool with
  ``{description, prompt, subagent_type}``. Like ``question`` it is
  intercepted by the session before the gate (``Session.execute_round/3``
  splits ``task_calls/1`` out), because a child needs the parent's
  RESOLVED config and must be bounded in depth. Its callback is a loud
  safety net: a call that ever reaches execution is a bug.
- **The child.** ``Core.Session.Subagent`` finds the named definition
  (``:subagent`` or ``:all``; never a ``primary``, and ``hidden`` is
  allowed — ADR 029 said the seam would need exactly that), starts a
  ``Session`` with ``depth: parent + 1``, ``interactive: false``,
  ``persist?: false`` and the parent's (already agent-narrowed) policy,
  runs one turn, and returns the child's final assistant text as the
  summary. The child's transcript never enters the parent context — only
  the summary does, as the ``task`` tool result.
- **Depth 1.** ``Tools.delegation/1`` returns the ``task`` tool only for
  a depth-0 scope; a depth-1 child's tool set excludes it. The gate also
  fails a depth-1 session's parked calls CLOSED instead of pausing
  (a subagent has no human channel, ADR 017); a depth-0 headless driver
  keeps the usual park/decide contract.
- **The events.** The parent publishes ``{:subagent_started, child_id,
  name, model}`` and ``{:subagent_finished, child_id, outcome}`` on its
  OWN channel. The TUI keeps a ``subagents`` map and lets the live band
  name the LEAF of the active delegation (``band_identity/1``), reverting
  to the primary when the child finishes. This satisfies the amendment
  above ("the running agent, whoever that is").
- **Ephemeral.** ``persist?: false`` skips the child's disk write (its
  summary is the durable record, in the parent), and ``Subagent`` deletes
  any stray child row after the turn, so a subagent never appears in the
  picker.

What is deliberately NOT here: the **subagent tab** (a key binding that
subscribes to the child id and paints its transcript), the two-slot
header's tab bar, and the model-precedence open question (definition
``model`` wins over the session model, per ``State.effective_model/1`` —
a deliberate first choice, revisitable).

**Known limitation (recorded, not hidden): esc does not stop a running
child.** The parent's turn worker blocks on the child's ``Session.run/2``
inside the ``task`` call; ``Core.Interrupt`` is cooperative between tool
calls, and an inline child is one call, so a stop arrives only after the
child finishes. The child has its own interrupt id, so the plumbing
exists (``Interrupt.request/1`` on ``child_id``); forwarding the parent's
stop to the active child is the natural follow-up, alongside the existing
"mid-tool hard cancel" note in ``ROADMAP.md``.

*Resolved in part (2026-09-30):* the parent's stop IS forwarded to every
active child (``esc_stop/1``), and the "mid-tool hard cancel" land below
the child is now built — ``Core.Exec`` observes the stop flag and kills a
running command (ADR 043). A child blocked in a `shell` therefore ends
within one poll tick, though the parent worker still blocks on the
``task`` call until the child returns.

Acceptance: ``test/coding_agent/core/session/subagent_test.exs`` (the
round returns the summary, ephemerality, unknown/primary types, a failed
child, depth 1 and the fail-closed gate, the parent events),
``test/coding_agent/core/tools_test.exs`` (the task tool's presence by
depth), and ``test/coding_agent/ui/tui_subagent_test.exs`` (the band's
leaf identity and its revert).

Amendment 2026-09-25 (ii): the subagent tab — the design, decided
-----------------------------------------------------------------

**Status: Accepted — SHIPPED 2026-09-25** (see the block at the end of
this amendment). This records the owner's decisions so the slice could
be built without re-litigating them. The seam it builds on
shipped in the amendment above; this amendment replaces the "active only,
no history" direction of the brainstorming list in ``TODO.md``.

Three things in the seam were not tab-ready. They were verified against
the tree before deciding (the build below then changed 1 and 2):

1. **The event wire carries no source id.** ``Events.publish/2`` sends
   ``{:agent, event}`` (``events.ex``), and every TUI handler matches the
   event SHAPE, not its origin (the ``handle_info({:agent, ...})`` family
   in ``tui.ex``). The TUI subscribes once, to the parent id. Subscribing
   to ``child_id`` as well would make child deltas and ``:status_changed``
   indistinguishable from the parent's and blend them into the parent
   transcript — exactly what part 3 of this ADR forbids.
2. **No unsubscribe, and no catch-up for early deltas.** Subscribing a
   child is fine — a session runs its turn in a worker task, so its
   process stays responsive and ``Session.subscribe/1`` does NOT block.
   But there is no ``Session.unsubscribe/1`` (the TUI must
   ``Registry.unregister`` itself), and there IS a race: the parent
   publishes ``:subagent_started`` and immediately runs the child, so
   deltas emitted before the TUI's subscribe lands are lost to the tab.
3. **``Subagent.cleanup/1`` deletes the child's display rows.** The child
   DOES write display rows through ``broadcast/2`` →
   ``record_display_event`` regardless of ``persist?`` (only the
   ``Store.save`` snapshot is skipped), but cleanup calls
   ``Store.delete(child_id)``, so nothing survives the child. Reading a
   RUNNING subagent's reasoning works only while it runs.

Decisions (owner)
..................

- **Child transcript: in the TUI's memory, not the store.** The tab
  accumulates the child's events in the ``subagents`` map the TUI already
  holds. Nothing is written to disk; after a restart only the parent's
  summary survives. This matches "only the summary is persisted" and
  avoids a schema migration, a ``parent_id`` column, and touching
  ``cleanup``.
- **Route by tagging the wire: ``{:agent, id, event}``.** ``Events.publish/2``
  carries the source session id; the TUI routes an event to a tab when the
  id is a known child, else to the parent view. Explicit and future-proof
  for several concurrent tabs. Unreleased, so no compatibility concern;
  every handler and the test seam (``TuiCase.agent/2``) change.
- **Parallel delegation with a configurable cap.** ``run_subagents/2``
  becomes concurrent (default ~3, sized to Ollama's parallel limit,
  configurable for a user who wants more), instead of the current
  ``Enum.map`` that blocks the parent worker on each child in turn. N
  repos can be delegated at once; the cap is a config value (ADR 014).
- **Keep every child tab of a session.** All subagents of a session stay
  readable, not just the running one. Because the store keeps only the
  summary, "keep" means in the TUI's memory for the life of the session
  view.
- **Navigation: a bounded tab bar plus ``ctrl-x``.** The bar shows the
  ACTIVE children (up to the cap) with a ``+N finished`` counter; finished
  tabs stay reachable through a ``ctrl-x`` entry ("subagents") that lists
  them. The bar stays bounded however many ran; ``ctrl-x`` reaches them
  all.
- **Render through the parent's transcript widgets, read-only.** The tab
  reuses the same widget/scroll/tool-accordion path as the main transcript,
  sourced from the child's event list — no second render truth (the
  ``measure = paint`` discipline).
- **Discard tabs on session switch.** Switching sessions via ``ctrl-x s``
  drops the in-memory child tabs; they belong to one session.

The slice, in order
....................

1. Tag the wire ``{:agent, id, event}``: ``Events.publish/2``, every TUI
   handler, and ``TuiCase.agent/2``. The parent view is unchanged.
2. Subscription hygiene: a self-register (``Process.monitor`` the
   child, ``Registry.unregister`` at finish) — no ``Session.unsubscribe/1``
   exists — and close the early-delta race: either have the parent relay
   the child's events itself, or seed the tab from the child's Store
   display rows when attaching (tool/info rows are written immediately
   and reasoning/answer rows at each round boundary, all regardless of
   ``persist?``), so the first moments are not lost.
3. TUI: on ``:subagent_started`` subscribe to the child and start
   accumulating its events; on ``:subagent_finished`` stop accumulating,
   keep the tab (finished) and unregister.
4. Route: child events go to the child's buffer, never the parent's.
5. View: a tab bar (active + ``+N finished``) and a ``ctrl-x`` "subagents"
   list; opening a tab renders the child's buffer read-only through the
   parent transcript path.
6. Parallel ``run_subagents/2`` with the cap, and forward the parent's esc
   to every active child (the known limitation from the amendment above).

**SHIPPED 2026-09-25.** All six steps above are implemented:

- The wire is tagged ``{:agent, id, event}``; ``Events.publish/2`` and the
  TUI router route a child's events to its tab, never the parent view.
- A child tab accumulates its own transcript/stream (in-memory) and its
  own scroll/open-tool state; the tab bar names the active children
  (``@tab_bar_cap`` 5) plus ``+N running`` / ``+N finished`` counts, and
  ``ctrl-x a`` opens the ``subagents`` popup (primary + every child,
  finished ones marked). Render reuses the parent transcript path.
- A finished tab is KEPT (read-only) until the view is discarded (a
  session switch resets the map).
- ``run_subagents/2`` runs a round's ``task`` calls concurrently, capped
  by ``Config.subagent_concurrency/1`` (default 3, ``config.toml
  subagent_concurrency``). Results keep call order.
- esc forwards the stop to every active child (each has its own
  ``Interrupt`` id), so a long delegation is cancellable.
- ``subscribe_child/1`` is best-effort (a child may be gone before the
  start event is processed).

Acceptance: ``test/coding_agent/ui/tui_subagent_test.exs`` (child-event
accumulation and parent isolation, the tab bar's appearance, opening a
tab), ``test/coding_agent/core/session/subagent_test.exs`` (concurrency,
result order), ``test/coding_agent/core/config_test.exs``
(``subagent_concurrency``), and the events tests (the tagged wire).

Still open
...........

- **Exact navigation keys** (open question 1): the ``subagents`` popup is
  the home today (``ctrl-x a``); single-key next/previous-tab is not bound
  (the popup covers the need; a chord would be a keymap addition, ADR 011).
- **Memory bound** for keep-all tabs: many long child transcripts live for
  the session's life. Accepted for now; revisit if it bites.
- **A finished child's display rows are still deleted.** Since the tab is
  in-memory this is fine today; a durable child transcript would need
  ``cleanup`` and a ``parent_id`` link — recorded so the path is known.

Amendment 2026-09-25 (sidebar): the panel is three blocks, headed by the scope
------------------------------------------------------------------------------

**Status: Accepted (the sidebar layout below is shipped).**

The panel had accumulated rows without a reading order: two identity
badges, a definition list that mixed *who acts* (session, effort) with
*what it costs* (tokens, context, compacts-at), the cost line, the help
chords — and a ``Block`` title ``" status "`` on top. The title was the
visible symptom: because the panel draws one border (``borders:
[:right]``), a title has no top rule to sit on, so it painted as bare
text one cell in from the edge — neither a heading nor content, and
indented relative to the rows below it. The word itself was also wrong
for the panel's job (it holds the scope, the identity and the token
numbers; "status" names one of its rows at best).

**The layout now has three blocks, separated by blank lines:**

.. code-block:: text

   agentic-coding-assistant-mjansen

   agent:    build
   model:    deepseek-v4.1-flash
   provider: ollama_cloud
   session:  tui-3396

   effort:      default
   tokens in:    12.4k
   tokens out:    3.1k
   context:      48.0k (9% win)
   compacts at: 180.0k tok

   ctrl-t toggles tools
   ctrl-x p hides panel

1. **The heading is a body line, not a title.** ``Styles.heading/2``
   renders one line in the ``:emphasis`` role (the stated body white,
   bold) — the role ``Palette`` has carried since the beginning and no
   call site used. As a body line it is flush with the panel's own
   content column, which is what makes it read as a heading of the
   content rather than chrome floating above it. The text is the
   **scope**: the last path segment of the session's ``scope_root``, the
   answer to "which repo am I in" (the full path is far wider than the
   36-column panel). ``scope_root`` is mirrored into the TUI state at
   mount, like the model and the effort — the render path must not call
   into the session per frame (the per-frame-load CPU lesson).
2. **Identity is one block: agent + model + provider + session.**
   ``model:`` and ``provider:`` are the two halves of the model spec
   (``"<provider>:<id>"``), split by the same rule ``Request.build/2``
   and ``ProviderHealth.probe_model/2`` use, so the panel names exactly
   the two things the wire request resolves. Before this, the spec rode
   one badge on the full panel width precisely *because* the definition
   list's label column clipped it; split, both halves fit whole and the
   special case is gone.
3. **Effort belongs with the tokens, not with the session id.** The
   reasoning-effort knob is a *cost* fact — it changes how much the model
   spends per turn — so it heads the token block. Labels are padded per
   block: ``definition_list/2`` pads to the widest label of its own list,
   so the identity block pads to ``provider`` (8) and the stats block to
   ``compacts at`` (11). One merged list would pad every identity row
   three cells wider to make room for a stats label.
4. **The agent rows keep the running/next split** (part 1 above): both
   while a turn is in flight and they differ, only ``next`` while idle.
   The value keeps the ``:agent`` role, so the identity colour survives
   the badge → definition-row move; the *shape* supersedes the badges the
   2026-09-23 amendment kept in the sidebar, the *split* does not. (The
   subagent-tab amendment above leaves this untouched: it changes what
   the band names, not how the sidebar renders the split.)
5. **The empty rows below stay empty.** The panel is short and the column
   is full height; the alternative (padding the content out to fill the
   column) is decoration. Recorded because it is a decision, not an
   oversight: TODO's O5 asked for exactly this call.

Acceptance: ``styles_test.exs`` (``heading/2`` is emphasis, bold, on the
surface's own fill; ``section_header/2`` stays muted), ``tui_cells_test.exs``
(the heading's cell is white+bold on the sidebar fill and shares ONE
column with the identity labels; ``model:`` and ``provider:`` own separate
rows), ``tui_agent_test.exs`` (the panel heads with the scope, the old
title string is gone), ``tui_visual_test.exs`` (the heading is the first
content row, the model is split, and both disappear with the panel when
``ctrl-x p`` hides it).

**Where this sits relative to the subagent tab** (the amendment above):
the tab adds a bounded tab bar above the transcript (shipped with the
subagent-tab amendment, ``@tab_bar_cap`` 5) and may yet add rows in this
panel — the layout here was chosen so a later block can be appended
without re-cutting the three that exist. The empty rows below the blocks
(a TODO.md O-number then) are deliberately independent of the tab work
and were left as-is by owner decision: neither reads the ``subagents``
map; the shipped tab bar took the row above the transcript and did not
touch this panel.

Amendment 2026-09-30: the band follows the view; tabs move to the composer; subagents in the panel
--------------------------------------------------------------------------------------------------

Three owner decisions after the first real subagent run, all closing
gaps that made the delegation invisible:

1. **The live band follows ``active_tab``, not ``active_subagent``.**
   There were TWO pointers: ``active_tab`` (what the transcript renders)
   and ``active_subagent`` (set on child start). ``band_identity/1`` read
   the second, so with the transcript on the parent the band still named
   the newest child — two answers to "who am I looking at". The rule is
   now one sentence, *the band describes the view the human is in*: on
   the parent tab it names the primary even while a child runs, on a
   child tab the child. ``active_subagent`` is deleted; nothing else
   read it.
2. **The tab bar moves from above the transcript to directly above the
   composer.** It switches which view the field and transcript show, so
   its home is the input, not the reading area. It stays one row, appears
   only once a child exists, and the active tab is now ``:accent`` (the
   old all-``:muted`` row was so quiet the owner never noticed it). The
   pane math (``layout_overhead/1``) is unchanged — one row either way.
3. **The sidebar gains a ``subagents`` block: the ACTIVE children only.**
   Name and model, the viewed tab marked (``▸``), finished ones dropped
   (their tab is kept, but they are no longer "what is happening"). This
   is the panel block the earlier amendment anticipated; bounded like the
   todo block (``@subagent_cap`` 8).

Amendment 2026-10-01: a failed child's tab tells its own story
--------------------------------------------------------------

Found live after the first real delegation: of two ``task`` children,
one returned a report and the other's tab ended on a bare reasoning
block. Cause: a child that DIES (a stream error) never emits the
``llm_message`` that commits its stream to the transcript, so its last
reasoning was left in ``stream`` — rendered as an in-flight block that
would never resolve — and the ``:error`` finish only appended
"· subagent ended with an error" to the **parent** transcript. The tab
therefore ended mid-thought, looking like the child simply stopped, with
the failure visible everywhere except the view that needed it.

``handle_info({:subagent_finished, id, outcome})`` now closes the child
through ``finish_child/2``: it commits the lingering stream to the
child's own transcript (the same ``persist_stream/2`` the happy path
uses) and, on ``:error``, appends the note to the CHILD's view as well
as the parent's. An ``:ok`` child already emitted its ``llm_message``
(stream empty), so its closure is a no-op — a successful child's answer
is never duplicated. This keeps the ADR-018 invariant intact: the child
transcript still never blends into the parent model context; only the
human-facing tab gained the closing line.

Amendment 2026-10-11: the tab strip joins the composer; the transcript loses its frames
---------------------------------------------------------------------------------------

Two owner decisions, both about what carries MEANING in the layout.

**1. The tab strip is part of the composer panel.** The 2026-09-30
amendment moved the strip from above the transcript to "directly above
the composer" and kept it a separate layout row. Measured at 100x30 with
one child: the strip's ``[primary]`` began in column 37 while the field
and the meta row began in column 38 — the strip alone sat flush on the
pane edge, because only the composer's own rect went through
``Composer.inset/1``. The owner's ruling: everything in the bottom box
answers one question (*how do I plan the next move* — which view, which
agent, which model, which mode), so it is ONE information unit and gets
ONE padding. The strip is now a segment of the composer's inner rect
(``Composer.split/2``) and its row is counted by ``Composer.height/1``,
so ``layout_overhead/1`` no longer carries a separate ``tab_h``. The
strip's position is unchanged; only its ownership is.

**2. The transcript's frames are gone.** The user message and the
assistant answer no longer carry a ``[:all]`` border, the expanded tool
output no longer carries one either, and the sidebar's ``[:right]`` rule
is gone. What replaces them:

* **One labelled rule per message.** A ``Block`` border paints its title
  ON the border row it occupies (verified against the drawn buffer), so
  ``borders: [:bottom]`` with a ``:bottom``-positioned, right-aligned
  title IS an HTML ``<hr>`` with the signature at its end —
  ``──────────────── you → build``. Rendered with ``border_type:
  :plain``: a rounded or dotted rule reads as a box edge, and there is
  no box.
* **Role colour, one marker, indent.** The body text is the stated
  white, reasoning is grey italic, the tool header keeps its ``▾`` and
  the output is indented two cells. That is what distinguishes the
  blocks; the palette was built for exactly this (``UI.Palette``).
* **The open tool box became a header and an indented body.**

Why the frames had to go, in one sentence: a framed entry that SCROLLS
must be re-anchored, because a full outline paints on the rect's edges —
as the entry's top rows leave the pane, the top border has nowhere to
live and either repaints at the pane top forever or is stripped by hand.
That arithmetic (``border_rows/1`` + ``window_border/2``) existed only
for the transcript, broke repeatedly ("empty lines at the end of the
block", "the box kept repainting while its content scrolled away"), and
is deleted. A one-sided rule has nothing to re-anchor: it is one row and
scrolls away with its message.

**The rule this leaves behind: a frame marks a MODALITY or a one-line
separation, nothing else.** Every remaining border is either a modal
overlay (menu, commands, files, picker, approval, budget, doom,
question — all painted last, over ``%Clear{}``, and none of them
scrolls) or the transcript's one-row rule. The gate's ``:double`` frame
stays as the "you are blocked, your keys go here" signifier. This is
recorded as a rule in ``UI.Styles``.

**Air.** ``@air`` drops from 3 to 1 for every block, the user message
included. The user's 0-air exception existed only to make the BOXED user
message stand out by contrast; without boxes the exception lost its
reason, so the gap is one number again (two consecutive tool calls were
4 rows apart).

Acceptance: ``transcript_view_test.exs`` (the heights: info 2, user 3 =
content + rule + air, assistant with wrapping, collapsed tool = header +
preview, open tool), ``composer_test.exs`` (the strip is the panel's
first row at the field's x/width; no strip, no widget and no row),
``tui_visual_test.exs`` (the expanded tool is a header plus an indented
body and no ``tool output`` frame; no rule glyph anywhere in the
sidebar), ``tui_cells_test.exs`` (the typed text is still the stated
white on the chrome fill), ``tui_agent_test.exs`` (the setup row is the
input rect's last row and carries no status).

Amendment 2026-10-11 (ii): the collapsed tool shows a preview; the hit-test measures what the painter paints
------------------------------------------------------------------------------------------------------------

**1. A collapsed tool block is no longer a single header line.** It is
``▸ name`` plus the result's first rows (``@preview`` 6), indented, and
one elision row when the output is longer; opening it (click, enter,
``ctrl-t``) replaces the preview with the full body. The header string
had TWO builders — ``Tui.entry_widgets/3`` built ``"▸ name: first
line"`` and ``TranscriptView.widget_for/3`` built the same shape for the
measurement probe — so the two could drift apart the moment either
changed. There is now one: ``TranscriptView.collapsed_body/2`` is called
by the painter and by the probe.

**2. The mouse hit-test measured a different width than the renderer.**
``state.last_pane_width`` was ``terminal_width - @width_overhead`` (4 =
app margin 2 + the pane's inner inset 2) and is now ``last_total_width``:
the raw terminal width. The renderer's width depends on two toggles that
a constant cannot know — the sidebar claims 36 columns, and the mid
column is capped at the ``@measure`` reading width — so the readers
measured 96 columns at 100x30 with the sidebar on while the painter used
60. A wrapped answer above a tool therefore reserved fewer rows than it
painted, and the tool's hit band sat ROWS ABOVE its own header: measured,
the header painted at frame row 6 and clicked at row 5, and clicking row
6 did nothing.

**3. The reader derives the pane from the frame; state stores no size.**
The fix for (2) still read the pane SIZE out of state — a copy the render
path refreshed only on a resize. The pane also moves for reasons that are
not resizes (the composer grows with the typed lines and the tab strip),
so the copy could be stale in both dimensions. Measured: with the sidebar
on, the click was mapped through a hard-coded pane offset of 1 while the
pane actually starts at row 1 but is 18 rows tall in a 30-row window —
the hit-test was one row off in the frame, so the fix above was still
landing the click on the wrong row. And a transcript that only GREW
between two resizes stayed clamped against the older extent.

There is now ONE geometry function, ``Tui.frame_layout/5``, from
``(width, height, sidebar?, input_h, band_h)`` to the frame's rects; the
renderer CONSUMES those rects and every reader — ``block_at_row/2``,
``clamp_scroll_now/1``, ``scroll_diagnostics/1`` — derives its pane rect
from the same function through ``Tui.pane_rect/1``. The inputs are the
terminal size the runtime reports (the declared virtual size under test,
the tty in production: ``term_size/1``) plus state that already exists,
so a reader cannot be a resize behind. Deleted with it:
``@layout_overhead``, ``layout_overhead/1``, ``last_pane_height``,
``last_total_width``, ``transcript_visible_height/1``,
``rederive_pane/1`` and ``pane_size/1``.

The one thing the poll still stores is the pane rect of the LAST PAINTED
FRAME (``last_pane_rect``), and no reader consults it: it only answers the
idle poll's question, "did the frame's geometry move under us?" — which is
how a composer that grew between resizes still gets its frame.

One cycle had to be broken to make this work: the composer's meta row
carries the scroll diagnostics, the diagnostics need the pane, the pane
needs the composer's height. ``Composer.height_for/3`` computes the height
from the three facts it depends on (a tab strip exists, the textarea's
line count, the line cap), so the TUI never builds a composer to measure
the pane; ``height/1`` and ``min_height/0`` are thin readers of it.

Acceptance: ``tui_accordion_test.exs`` ("the clickable row IS the painted
header row, with the sidebar on and wrapping above"); ``tui_visual_test.exs``
("the pane geometry the reader measures is the one the painter painted"
over three terminal sizes with and without a tab strip, and "the pane the
readers measure follows the composer, with no resize");
``tui_cells_test.exs`` ("the band is painted in the SAME frame rows the
layout reserves for it").

Amendment 2026-11-01: the panel is a module, and the live blocks move up
-----------------------------------------------------------------------

Two changes in one, because they touch the same lines.

**The panel left the TUI.** ``sidebar_widget/1`` and its twenty row
helpers lived in ``UI.Tui`` under the ``# -- Subagent tabs`` marker —
the sidebar had no marker of its own, so the only way to find it was to
read until ``defp sidebar_widget``. It is now ``UI.Sidebar``: a module
that takes a struct of already-resolved values (``new/1``) and returns
one widget. Nothing in it reads the session, the config or the clock, so
the panel's order is unit-testable without a terminal
(``sidebar_test.exs``), and the TUI keeps what only the TUI can know —
which fields to resolve (``sidebar_panel/1``).

The number spellings left too. The token abbreviation and the money rule
were duplicated between the panel and the ``/stats`` popup; they are now
``UI.Format`` (``k/1``, ``money/1``, ``money_rows/1``, ``effort_name/1``),
read by both. Formatting is not painting, which is why it is its own
module and not part of the panel.

**The reading order changed.** The panel answered its questions in the
order the rows had accumulated, not in the order a reader asks them: nine
reference figures sat between the identity and the two blocks that
actually move. Now:

.. code-block:: text

   <scope>

   agent:    build
   model:    deepseek-v4.1-flash
   provider: ollama_cloud
   session:  tui-3396

   subagents
   · explore · glm-5.3-flash          <- only while something runs

   todo
   ○ read the code                    <- only when the model plans

   effort:      default
   tokens in:    12.4k
   tokens out:    3.1k
   context:      48.0k (9% win)
   soft at:     180.0k tok
   hard at:     320.0k tok
   last round:    4.2 s + 600 ms
   catalog:     2026-08-23 (55d)

   cost:      $0.2500 (billed)
   credits:   $4.00

   ctrl-t toggles tools
   ctrl-x p hides panel

The rule is *dynamic before static*: subagents and todo change while the
session works, so they sit above the figures, which only move at a round
boundary. The identity stays above both because it answers the first
question ("who is doing this"), and the key hints stay last because they
are read once.

Accepted by ``sidebar_test.exs`` as an order (the label sequence), so a
future reorder has to say so in the test: the heading first, identity
before figures, the two live blocks above them, and every absent block
(no subagents, no todos, no money, no catalog row) painting nothing at
all.

Amendment 2026-11-01 (ii): the dialogs, the stats snapshot and the overlay geometry leave the TUI
------------------------------------------------------------------------------------------------

The same pass that moved the sidebar found three more clusters in
``UI.Tui`` that were painter code living in a GenServer module:

- **``UI.Dialogs``** — the four blocking surfaces (approval gate, tool
  budget, doom loop, question wizard). They share one frame and one
  failure mode (a dialog that does not fit its room, or two painting at
  once), and they were 300 lines at the bottom of a 6000-line file. The
  wizard's markdown body moved with them, since the def-list rules
  (flatten every model-supplied line, separate blocks with an empty
  blockquote) are the dialog's own contract, not the TUI's.
- **``UI.Stats``** — the ``/stats`` body and its two exits (the file
  beside ``tui.log``, OSC 52 to the clipboard). It is the detail view of
  the two mirrors the sidebar shows at a glance.
- **``UI.Overlay``** — the room and the rect every overlay is placed in.
  The reading measure, ``area.height - 4`` and ``area.height - h - 3``
  were spelled at each call site; the second one put a 26-row menu on a
  30-row window at a negative row. One ``room/2`` and one ``rect/4`` now,
  with the input height passed in rather than read from a state struct.

What stays in ``UI.Tui`` is the one thing only the TUI knows: which
fields to resolve (``sidebar_panel/1``, ``stats_snapshot/1``,
``dialogs/1``) and which surface is up. The painters take resolved
values, so all three are unit-testable without a terminal
(``dialogs_test.exs``, ``overlay_stats_test.exs``).

Amendment 2026-11-01 (iii): the text layer leaves the TUI, and the region move is a tool
----------------------------------------------------------------------------------------

Two changes that belong together: the largest remaining cluster of pure
code in ``UI.Tui`` moved out, and the operation that moved it became a
tool instead of three ``sed`` deletions.

**``UI.Display`` is what the text looks like.** Six scattered regions —
the stream buffer, the reasoning shape, the tool cap, the answer
breathing, what a finished block becomes, and the two display lists —
were spread over 700 lines of a GenServer module, four of them separated
from their only caller by hundreds of lines of event handling. They are
one module now, because they answer one question: given a transcript and
a stream, what rows does the painter draw?

The module's reason to exist is a contract, not a tidy file: three
consumers read the same string and must not disagree — the measure
(``TranscriptView.height/3``) renders the widget to count rows, the paint
builds the same widget, and the persistence decides what a finished block
becomes in the transcript. Every disagreement between them has landed the
same way, an entry reserving rows the widget never paints, and the
"scroll up three screens of blanks" bug is the canonical one. So the shape
is applied once, in one place, and the render path trusts it.

What the TUI keeps is the resolution of values, the same division as
``sidebar_panel/1``: ``display_entries/1`` reads four fields off the
state and hands them to ``Display.entries/4``. Nothing in ``Display``
reads a state struct or a clock, so the shapes are unit-testable without
a terminal (``display_test.exs``), which they were not before: every one
of these functions was a ``defp`` reached only through a running TUI.

**The move itself is ``move_region`` (ADR 045).** The sidebar pass and the
dialogs pass were done with hand-written ``sed -i`` deletions, and one of
them mis-attributed a compile error to the wrong file. This pass used
``Tools.MoveRegion``: six anchored moves, each dry-run first to read the
line numbers, then applied. The first ``mix compile`` after the moves
reported exactly what the tool's own message predicts — the moved block
does not carry its aliases — and the rewire was mechanical. Measured cost
of the anchor scan: 1.0 ms per move on a 208 KB file, which is why the
tool takes anchors and not line numbers.

``tui.ex``: 6044 → 5008 lines across the three passes.

Amendment 2026-11-01 (iv): the tab slice leaves the TUI, as a struct
--------------------------------------------------------------------

**``UI.Tabs`` is the subagent tabs.** Everything the four earlier
amendments in this file decided about tabs — the tab model, the one
pointer, the per-view scroll and expand state, the tab strip, the popup
rows — was still spread through ``ui/tui.ex``: five functions under
"active-view routing", ten under "Subagent tabs", the strip and its
``@tab_bar_cap`` in the composer's section, and the popup builder between
two other menus. They answer ONE question — which views exist, which one
is on screen, and where each one sits — so they are one module now.

**The slice is a struct, not a map.** The state the TUI held was four
loose fields (``subagents``, ``active_tab``, ``scroll_offset``,
``open_tool_id``) whose invariant — "one pointer into ``subagents``, every
consumer goes through it" (F4) — was a comment on the state struct, not
something the type could hold. It is ``state.tabs = %Tabs{}`` now: the
pointer and the map it points into are the same value, and each child is a
``%Tabs.Child{}`` instead of an anonymous map. The primary view's own
position lives beside them (``primary_scroll_offset``,
``primary_open_tool_id``), so "every view keeps its own position" is one
accessor pair (``scroll_offset/1``, ``put_scroll/2``) that dispatches on
the active view rather than a field name that differs per view.

The F4 rule is now unrepresentable-wrong rather than merely documented:
``active_child/1`` is the single reader and ``open/2`` the single writer,
so a stale pointer reads as the primary for the transcript, the scroll,
the expand state, the strip and the popup mark at once (pinned by
``tabs_test.exs``).

**What stays in the TUI, and why.** The band's identity
(``band_identity/1``) reads the active child, but the band is the VIEW's
row, not a tab property — its fallback is the primary's running agent, and
that lives in the session state. The clock helpers (``band_elapsed_s/1``,
``band_label/1``, ``pause_label/1``, ``esc_hint/1``) never touched a tab
and did not move. The session calls the slice cannot make on its own
(``Session.interrupt/1`` per running child, ``Session.unsubscribe/1`` on
finish) DID move, because they are the tab's own lifetime:
``interrupt_running/1`` and ``finish/3`` own them, and the TUI only calls
one function.

``Sidebar.new/1`` deliberately keeps its ``subagents``/``active_tab``
arguments: the panel is a painter handed resolved values, and a
``%Tabs.Child{}`` answers ``Map.get/2`` exactly like the map it replaced.
Narrowing that contract to the struct is a separate, smaller slice.

**Test seam moved with the data.** The integration tests
(``tui_subagent_test.exs``, ``tui_visual_test.exs``,
``tui_accordion_test.exs``, ``tui_menu_test.exs``,
``tui_resume_test.exs``) asserted ``state.subagents`` / ``state.active_tab``
/ ``state.open_tool_id`` directly; they assert through the module now
(``Tabs.active_id/1``, ``Tabs.open_tool_id/1``) and build fixtures as
``%Tabs.Child{}``. That is the cost of the struct and it is the good
direction: a test that pokes a field name breaks on every reshape, a test
that asks the module survives it.

``tui.ex``: 5026 → 4803 lines (``ui/tabs.ex``: 382). Suite 1493 → 1507
(``tabs_test.exs``: 14 tests, terminal-free).
