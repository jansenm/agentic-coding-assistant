.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

Doom-loop guard: pause on repeated identical calls
===================================================

.. adr::
   :id: 026
   :status: Accepted
   :date: 2026-09-23
   :tags: sessions, agents, tools, prompts

.. note::
   Accepted and implemented 2026-09-23. Answers T2's detection half in the
   ``TODO.md`` "rival opencode" list — the half ADR 025
   deliberately left open. Detects a repeated call and pauses an
   interactive driver (continue / reject); a driver that cannot answer is
   steered silently. Built on ADR 025's pause machinery.

Context
-------

The harness's only runaway protection is a numeric cap (ADR 025). A
count cannot tell a legitimate long task from a real loop; only the
*repetition* can. The "five minutes in circles" failure — the model
re-emitting the same call, seeing the same unhelpful result — is
invisible to a round counter until the budget trips, by which point the
turn is wasted.

opencode catches it by pattern. From its source
(``packages/opencode/src/session/processor.ts``, MIT, 2026-09-23):

.. code-block:: ts

   const DOOM_LOOP_THRESHOLD = 3
   const recentParts = parts.slice(-DOOM_LOOP_THRESHOLD)
   if (recentParts.length === 3 && recentParts.every(p =>
         p.tool === value.name &&
         JSON.stringify(p.state.input) === JSON.stringify(input)))
     yield* permission.ask({
       permission: "doom_loop", patterns: [value.name],
       ruleset: agent.permission,
     })

Three consecutive identical calls (same tool, structurally equal args)
raise a ``doom_loop`` permission ask — default ``ask``, so the user gets
a dialog. Two properties are worth stating because the backlog's summary
("re-prompts with a nudge") was **wrong** about both: it is a *permission
ask*, not automatic steering, and it is checked per stream part, not per
round.

Decision
--------

**1. Three consecutive identical ROUNDS pause an interactive driver.**
The session keeps a per-turn window of the last three rounds'
signatures. A round's signature is its sorted list of ``{name, args}``,
so two rounds are "the same" when they asked for the same calls
regardless of order. When the window is full and all three are equal,
the session parks at ``:interrupted`` with ``State.doom_pause`` holding
the tripped round, and broadcasts
``{:status_changed, :doom_reached, %{tool: name}}``.

**2. The window is over ROUNDS, not individual calls — a deliberate
divergence from opencode.** opencode compares consecutive stream *parts*,
so three *parallel* identical calls in one assistant message would also
trip its guard. That is usually a legitimate fan-out (the same read of
several paths the model chose to repeat, or the model asking for the
same thing three times on purpose), not a loop. A loop is the model
re-emitting the same call *across rounds* after seeing the result. The
round-level window matches the failure mode and avoids the false
positive; the divergence is recorded here rather than hidden.

**3. The driver answers continue or reject.** ``Session.doom_decision/2``:

- ``:continue`` runs the repeated round anyway (the user judges the
  repetition correct — e.g. a poll);
- ``:reject`` does **not** run it: every held call is answered with a
  synthetic tool result steering the model off the repetition
  ("you have called X with the same arguments three times; repeating
  will not help — change approach or ask"), and the turn continues. This
  mirrors ``:stop`` at the budget and reuses ``steer_round/3``.

**4. A non-interactive driver is steered silently.** With no one to ask,
a detected loop answers the round with the same synthetic steering
result and continues. The rule from ADR 025 holds: the session never
hangs on a question nobody can answer. This is the backlog's original
"silent steer" idea, used as the fallback rather than the primary.

Consequences
------------

- A genuine loop is interrupted after three identical rounds — before the
  budget — and the model is given a concrete reason to change approach.
- Detection is cheap: one small per-turn list, no provider call, no new
  context shape. The round exchange is still appended atomically.
- ``doom_pause`` is durable like ``budget_pause``; a resume re-offers the
  dialog. ``recent_calls`` is runtime-only and reset per turn.
- A ``decide/2`` against a doom pause is refused, so the three
  ``:interrupted`` reasons (approval, budget, doom) cannot be confused.
- The threshold is a fixed 3 (opencode's value). It is **not** yet a
  config knob or a per-model calibration; if dogfooding shows it too
  eager or too lax, that is the next change (open question 1).
- Detection sees only ``{name, args}``. Two calls that differ in a way
  the model considers meaningful but the args do not capture (e.g. a
  shell command whose effect changed) are treated as identical; the
  dialog exists precisely so the human can overrule this.

Open questions
--------------

1. Should the threshold be configurable (``config.toml``, like
   ``max_tool_rounds``) and/or per model family (the ADR 024 calibration
   surface)? Three is opencode's value; we have no data of our own yet.
2. Should ``:continue`` at the doom prompt also suppress detection for
   the rest of the turn (the user just said "this repetition is fine"),
   or is re-asking on further repetition correct? Currently it re-asks.
3. Should the guard run *before* the budget check (a loop is more
   specific than a count) or after? Currently the budget is checked
   first, matching ADR 025's ordering; a loop at the budget boundary is
   reported as a budget trip.
