:orphan:

The model sees its context budget, and notes are where facts survive
======================================================================

.. adr::
   :id: 040
   :status: Accepted
   :date: 2026-09-30
   :tags: sessions, agents, prompts, compaction

.. note::
   Accepted and implemented 2026-09-30; decision 5 added the same day
   after the first live run. The model is told, on every request, how
   full its context window is and where the two automatic summarization
   lines sit, and is given (via the todo ``notes`` field, ADR 031
   amendment) a durable place to put facts that must survive
   summarization. **The soft and hard passes themselves are unchanged** —
   the original half of this record was *visibility only*, and that is
   still true of the AUTOMATIC policy. But the experiment's second half
   (open question 1, closed 2026-09-30) added a ``compact`` tool: the
   model can trigger a summary itself, so the record is no longer
   "visibility, not control" as a whole. See decision 5.

Context
-------

The two automatic compaction passes (ADR 037) are invisible to the model:

  * the **soft** pass summarizes older messages when a turn ENDS and the
    context is past ``soft = window/2``;
  * the **hard** pass summarizes pre-call at ``hard = window - reserve``,
    and degrades to a lossy trim if the summarize call fails.

A long single turn that grows past soft but stays under hard therefore
gets no summarization until it ends — and a task that runs 30+ tool
rounds in one turn may never reach the turn boundary. Observed live: a
review turn sat at ~350k of a 500k window (past soft, under hard) for an
hour, accumulating tool output, with no compaction and no way for the
model to know it was there. The model cannot manage a budget it cannot
see.

Decision
--------

**1. A per-call context-budget block.** ``Prompt.with_budget/2`` appends
a block to the system message on every request, through the same per-call
channel as the environment (ADR 024) and todo (ADR 031) blocks. It states
the projected context size, the window, and both limits::

    Context budget: ~350k / 500k tokens (70%). Older messages are
    summarized automatically at 250k when your turn ends, and forced at
    436k before a call.

The numbers are read from the SAME ``Compactor`` helpers the sidebar
mirrors and the decision uses (ADR 029), so display, prompt and
behaviour never disagree *with each other*. They can still be jointly
stale for the model actually in use — ADR 037 OQ1 (the window on a model
switch) — which is why a switch now re-resolves the window (review N9).

**2. An action hint only near a line.** Past soft, the block adds: finish
the current step and end the turn so summarization happens with headroom,
and put durable facts in a todo's ``notes`` first. At hard, it says
summarization is imminent. Below soft there is no hint — a session with
room is not nagged.

**3. ``notes`` is the durable place.** Facts that must survive
summarization go in a todo item's ``notes`` (ADR 031 amendment): it is
re-sent on every request, so compaction cannot eat it, and it is not
shown in the human's panel. The prompt states this explicitly, because
the survival property is the whole point of the channel.

**4. The prompt tells the model the mechanic.** Both framework prompts
gain a short "Context budget" section: the line exists, summarizing is
lossy, use ``notes`` for durable facts, and end the turn at a step
boundary when past the line.

**5. The model gets its own lever: the ``compact`` tool (amendment
2026-09-30).** See open question 1 (now closed). The tool is described
there; it is registered in the read-only bucket (intercepted by the
session, like ``todowrite``), and the budget block names it in every
case so the model knows the verb exists before it is at a wall.

Consequences
------------

- The model has the same information the human has, at the same moment:
  it can choose to wrap up a step rather than be summarized mid-think.
- Nothing about WHEN compaction fires changed. This is additive: if the
  model ignores the block, behaviour is exactly as before.
- The block rides every request, so it costs a fixed few tokens per call.
  It is not persisted and not part of the stable prefix (it changes every
  call, like the environment block), so it does not affect caching of the
  stored prompt.
- ``notes`` is bounded (per item and in total, ``TodoWrite``), because it
  too rides every request.

Open questions
--------------

1. **Does it help? — CLOSED, and the second half is BUILT (2026-09-30).**
   The first long agent run answered it: over a full day of review work
   the model triggered **no** compaction of its own and **was**
   auto-compacted mid-turn three times (plus four turn-end soft passes).
   It saw the budget line but had no lever beyond ending its turn. The
   `compact` tool is therefore built (``Core.Tools.Compact``): the model
   can summarize the older span NOW, mid-turn, exactly like the human's
   `/compact` — it ignores the thresholds ("is it over a line?" is the
   wrong question when the model has decided it wants headroom), is
   intercepted by the session like ``todowrite``, and returns a one-line
   result (how much was reclaimed, or "nothing to compact"). The budget
   block now NAMES the lever in every case, so the verb is known before
   the wall, and the guidance past soft/hard points at it. Whether the
   model uses it WELL (not too early, not instead of recording notes) is
   the open half of the experiment.
2. **The soft pass still cannot fire mid-turn.** Visibility lets the
   model *end the turn* to trigger it, but a turn that must stay open in
   one shot still relies on the hard pass. A round-boundary soft pass is a
   separate, mechanism-side option; this ADR does not decide it.
3. **Notes vs a dedicated memory block.** If the checklist shape proves a
   poor fit for facts, a dedicated notes/memory block (its own injected
   section and panel space) is the follow-up. Start with the todo field,
   which reuses the existing survival channel.
4. **The budget on a model switch — CLOSED (review N9).** The block made
   ADR 037 OQ1 visible: after a model switch the line reported the OLD
   model's window. ``Session.recompute_window/1`` now re-resolves on every
   effective-model change, so the block, the sidebar and the decision all
   track the current model.

Amendment 2026-10-22: the line states its own denominator, and the calm band gets advice
-----------------------------------------------------------------------------------------

**Status: Accepted (amendment to the accepted ADR 040); implemented with
this record.**

Context
~~~~~~~

Two measurements made the block's wording wrong in ways the original
record could not have anticipated.

**The percentage is the window's, the decision is the line's.** Decision 1
reports ``used / window`` as a percentage, and below soft that percentage
is the only number that moves. It was correct while both limits were a
fraction of the window: 70% of the window and 70% of the way to soft were
the same claim. The absolute keys (ADR 037 amendment, 2026-10-22) break
that identity. On the owner's model (window 1 048 576, soft 140 000,
hard 150 000) a context of 110 000 shows ``11%`` — three quarters of the
way to the soft line, reading as an idle session. The model said so
itself, in its own reasoning over that very block: *"~110k / 1000k tokens
(11%). That's misleading: on a 1M-window model with soft at 140k, 11%
sounds calm."* A statement the reader has to correct is worse than no
statement: the number was right and the question it answered was not the
one being decided.

**The lever exists, is named, and is never used.** The open half of open
question 1 had an answer available in the store: across seven sessions
(5 135 tool rows), the model called ``compact`` **zero** times, while the
harness auto-compacted **23** times in the one long session — every one
of them after a turn had ended (20 after an answer, 3 after an ``esc``
stop), none of them a mid-turn hard-limit pass. It quoted the budget line
in its reasoning 27 times. It was not blind to the number; below soft it
had nothing to act on, and the sessions never reached hard, so the
mechanism never forced the question either. Cost is what makes this
expensive rather than merely untidy: the owner measured ~**1 cent** at
150 000 tokens and ~**5 cents** at 180 000 in peak hours, so the calls a
timely ``compact`` would have prevented are the ones at the top of that
curve — and an absolute ceiling (150 000) is exactly the setting that
turns the hard pass into a mid-turn event.

The owner's framing also matters for what is NOT built here: the
experiment's target is an agent that plans its work in steps and decides
to compact at a step boundary, with persistent storage to carry the plan.
Until that exists, the block can only say what is coming and what the two
levers are.

Decision
~~~~~~~~

**1. Both denominators are named, and each line carries its distance.** The
line states the window, then the soft and hard lines and how far away each
is::

    Context budget: ~120k / 1.0M tokens (11%). Soft line 140k (20k away),
    hard 150k (30k away). Older messages are summarized automatically at
    the soft line when your turn ends, and forced at the hard line before
    a call; you may also call the `compact` tool any time to summarize the
    older span now and free room.

Past a line its distance becomes ``(passed)``. The percentage stays —
it answers "how much of the model's capacity is in use", which the human
also wants — but it is no longer the only quantity, and the quantities the
decision uses are stated in the unit the decision uses. The hard distance
is the one that matters in the band, because past hard the summary is
forced rather than offered.

**2. The band between the approaching threshold and the soft line gets
advice.** Decision 2 gave a hint past soft and none below it. The band
now says the two ways to act *before* the line is forced, and that
``notes`` is what survives either way::

    You are 40k below the soft line. Two ways to act before the hard
    limit forces it: end your turn at a step boundary (the idle pass then
    summarizes with headroom, at no latency cost to your next prompt), or
    call `compact` to free room inside this turn. Either way, put durable
    facts (paths, numbers, decisions) in a todo's `notes` first — notes
    survive summarization, older messages do not.

Below the threshold nothing is added: a sentence sent on every request
must earn its tokens.

**3. One threshold, not a second copy.** The band's lower bound is
``Compactor.warn_threshold/1`` — the function ``warn_approaching/1``
already uses for the human's note — passed into the block as
``warn_at``. The model's advice and the human's note therefore fire at
the same number by construction (ADR 029), instead of a ``0.8`` in the
prompt module that would drift from a ``0.8`` in the compactor. The
threshold is the caller's fact, not the formatter's: it arrives in the
``%ContextBudget{}`` and the formatter never derives one (second
amendment below — the field is required, so it cannot be silently
absent either).

**4. The framework prompt says ACT AT A STEP BOUNDARY, not "when you pass
the line".** The old instruction only described behaviour past the line,
which is the moment the automatic pass has already begun to compete with
the model's own plan. Both prompts now name ending the turn and
``compact`` as the two actions and state why not to wait for hard: there
the summary is forced before the next call, with no choice about where it
lands.

Consequences
~~~~~~~~~~~~

- The block is longer by one clause in every case and one sentence in the
  band. Both ride every request and are not part of the cached prefix
  (they change per call, like the environment block).
- The human's note and the model's advice share a threshold, so a session
  can be watched for whether the advice at 80 % of soft produces a
  ``compact`` before the soft line arrives. That is the measurement this
  amendment is waiting on; it is not claimed here.
- Nothing about WHEN compaction fires changed. As in the original record,
  a model that ignores the block behaves exactly as before.

Open question (new)
~~~~~~~~~~~~~~~~~~~

1. **Does the band advice produce a decision, or just a sentence?** The
   zero-of-5 135 measurement is the baseline. What would answer it: a
   session that crosses the band and either (a) calls ``compact`` inside
   the turn, or (b) ends the turn at a boundary and lets the idle pass do
   it — counted against the auto-compactions it did not need. A model that
   keeps working through the band and gets summarised mid-step is a
   negative result, and the next lever is the mechanism (a round-boundary
   soft pass, still open question 2) rather than more text.

Amendment 2026-10-22 (2): the block's facts are a struct, not a map
-------------------------------------------------------------------

**Status: Accepted (amendment to the accepted ADR 040); implemented with
this record.**

The block's seven numbers (``used``, ``window``, ``soft``, ``hard``,
``warn_at``, ``rounds``, ``max_rounds``) travelled from
``Session.budget_info/1`` to ``Prompt.with_budget/2`` as a bare map that
the formatter matched field by field. Every field was optional at compile
time. The first amendment made that a real defect rather than a latent
one: ``warn_at`` was added, and a producer that forgot it did not fail —
the band advice simply did not appear, which is indistinguishable from
"the session is below the threshold". A renamed key is the same failure
with a missing clause: ``"Older messages are summarized automatically at
when your turn ends"`` compiles and ships.

``CodingAgent.Core.Session.ContextBudget`` states the seven fields once,
with ``@enforce_keys`` on all of them and a type that forbids the values
that would render a lie (``window: 0``, a negative ``used``,
``max_rounds: :infinity``). ``ContextBudget.from_state/2`` is the
production constructor: it reads everything from the state the sidebar
mirrors and the decision uses (ADR 029), and takes ``max_rounds`` as an
argument because that number is resolved agent → session → config by
``Session.tool_budget/1``, not held in the state.

Consequences:

- A field added to the block is a compile error at every producer until it
  is supplied. A field removed is a compile error in the formatter.
- The ``:infinity`` tool-round variant disappears with the map: the guard
  always resolves a real budget (``Config.max_tool_rounds/1`` has a
  built-in default), and the old branch had no reachable production case —
  only a test constructed one. The block now always states
  ``n / max``.
- ``Prompt.with_budget/2`` keeps a no-op clause for a non-struct argument.
  That is not a second producer: a caller with no resolved window (a
  hand-built test state) has no block to send, and refusing loudly there
  would fail a request over a display detail.

