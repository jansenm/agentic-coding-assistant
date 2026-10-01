:orphan:

Compaction runs as a named, hidden agent
========================================

.. adr::
   :id: 044
   :status: Accepted
   :date: 2026-10-01
   :tags: compression, agents, prompts, models

.. note::
   Accepted and implemented 2026-10-01. The summarizer runs as the agent
   named ``compaction`` when a definition exists, so a user can give it a
   MODEL (a cheaper worker) and a PROMPT (what this repo's summaries must
   preserve) in one file — no new config key. Ships a default
   ``compaction.md``; its model is unset, so out of the box the behavior
   is unchanged. It also adds the agent mode ``:internal`` (driven by the
   runtime, not selectable or delegatable).

Context
-------

Two questions met here:

1. **Which model summarizes?** Compaction is one long provider call doing
   mechanical text work — the shape where a cheaper model pays. ADR 042
   added ``subagent_model`` for exactly this reason on the ``task`` path,
   so the obvious move was a sibling ``compaction_model`` key.
2. **What must a summary preserve?** The built-in template (ADR 037) sets
   the shape, but "what matters in THIS repo" is user knowledge — a
   compliance repo wants ticket ids kept, a docs repo wants the doc
   structure. There was no way to say so.

A config key answers (1) and not (2). An agent answers both: a definition
already carries ``model``, ``prompt``, ``temperature`` and ``max_turns``,
layered and validated like every other agent (ADR 017). The user writes
one file and gets a tuned summarizer; the code path is the one already
proven for subagents.

opencode reached the same shape independently: its compaction is a hidden
agent (``name:"compaction"``). We checked its compiled 1.18.34 — and in
doing so CORRECTED a claim in our own research page: opencode does **not**
run compaction on a separate small model; without a configured model it
uses the session model (``small_model`` feeds only title generation). So
the agent-shaped solution is not "borrowed from a different-model
opencode"; it is the same problem, solved the same way.

Decision
--------

**1. The summarizer resolves an agent named ``compaction``** from the
standard layers (shipped → user → project, ADR 017). Its ``model`` (when
set) is used; otherwise the session's effective model. Same precedence as
ADR 017 decision 5 / ADR 042: definition wins, config/runtime is the
fallback.

**2. The prompt body is the SYSTEM message; the template stays the USER
message.** The system message says *what to prioritize* ("always keep the
ticket id", "carry the migration order verbatim"); the user message stays
``Compaction.summary_prompt/2`` — the fixed section layout and the
span. They ADD rather than replace, so a user cannot break the structure
the rolling summary depends on (ADR 037 decision 5). A definition with no
body, or no definition at all, sends no system message — exactly today's
request.

**3. An agent mode ``:internal``.** A compaction agent is neither a
*persona* (``:primary``) nor a *delegatable capability* (``:subagent``):
the runtime drives it by name. ``:internal`` is excluded by the existing
``selectable?/1`` (``mode in [:primary, :all]``) and by
``Subagent.delegatable/1`` (``mode in [:subagent, :all]``) with no new
rule — it simply appears in neither set. opencode marks its compaction
agent ``primary`` + ``hidden``; a real mode is more honest than leaning on
``hidden`` to keep it out of the picker.

**4. A default ``compaction.md`` ships.** Model-less (inherits the session
model) with a body that names the generic priorities — exact identifiers,
measured numbers, rejected approaches, standing directives, open problems.
It is visible and overridable, and it documents the mechanism by existing.

Consequences
------------

- Out of the box the request is unchanged (session model, template only):
  the default agent adds a system message describing generic priorities,
  which is a prompt change but not a behavior/limit change.
- A user sets a cheaper compaction model with ``model:`` in
  ``.coding-agent/agents/compaction.md`` — no new config key, and the same
  file tunes the prompt. This is the ``compaction_model`` idea, subsumed.
- **The pinned model's window is enforced (implemented with this record).**
  A pinned compaction model must be able to HOLD the span, or the call
  fails on large sessions. ``Compactor.compaction_target/1`` resolves the
  model and the span cap together from the catalog window:
   ``Compactor.resolve_target/3`` gives a pinned model a span capped at
   half its window (chars = ``tokens × 4 × 0.5``, never above the 300k
   default), and if that cap is below ``@min_viable_span_chars`` (20k) the
   pin is DROPPED and the session model summarizes. An UNKNOWN or loading
   window also falls back to the **session model** with the default cap
   (review N58): the pin's window cannot be verified as big enough, so it
   is not trusted with the full span — the branch a first over-limit turn
   hits, because the catalog warms in the background. The span and the
   model come from one call, so they cannot disagree.
- The template's section names are load-bearing (rolling folding reads the
  prior summary); a user body cannot change them, only the priorities.

Open questions
--------------

1. **A pinned model that is too small is silently ignored.** We fall back
   to the session model rather than warn. A transcript note ("compaction
   model X's window is too small; using the session model") would be
   friendlier; deferred until it bites in practice.
2. **Per-tool/per-turn summarizer variants.** One ``compaction`` name
   today. If a need appears for different summarizers (idle vs. model-
   triggered), that is a naming/selection question, not a new mechanism.
3. **Does a custom body help?** Same experiment stance as ADR 040: the
   default body is a hypothesis; the next long runs show whether user
   bodies measurably improve the resumed agent's accuracy.
