:orphan:

The model sees its context budget, and notes are where facts survive
======================================================================

.. adr::
   :id: 040
   :status: Accepted
   :date: 2026-09-30
   :tags: sessions, agents, prompts, compaction

.. note::
   Accepted and implemented 2026-09-30. The model is told, on every
   request, how full its context window is and where the two automatic
   summarization lines sit, and is given (via the todo ``notes`` field,
   ADR 031 amendment) a durable place to put facts that must survive
   summarization. This is VISIBILITY, not control: the soft and hard
   passes are unchanged. It is the first half of a "let the agent manage
   its own context" experiment; forcing more compaction on it is
   deliberately NOT part of it.

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

1. **Does it help?** This is the experiment. The next long agent run
   shows whether the model self-regulates (ends turns / records notes) or
   ignores the line. A self-triggered ``compact`` tool is the natural
   second half IF the experiment shows the model wants to act but has no
   lever beyond ending the turn (which costs a human re-prompt). Not
   built here — forcing more compaction is deliberately deferred.
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
