Context Compaction Strategies
=============================

This page records what other coding agents do to a conversation when it
outgrows the model window, so the *next* compaction decision here is
grounded in their practice rather than in our own reasoning alone. It is
**research, not a decision** — it compares approaches and notes what we
might adopt, but commits to nothing. The decisions we have made are ADR
023 (compaction) and ADR 037 (two limits); the prompt-visibility
experiment is ADR 040.

The question this page answers is narrow and specific: **when context
must be deleted, how does a tool make sure the *right* things are kept
and the rest dropped?** The answer turns out to have four independent
parts — what the summarizer is told, whether summaries accumulate, what
gets erased without a model, and where the boundary between "keep" and
"summarize" is drawn.

The reference is **opencode** (version 1.18.33, read 2026-09-30 from the
upstream source, repository ``anomalyco/opencode``, MIT — the same
project the earlier ADRs cite). It is the closest sibling to this
harness, so it is the most useful comparison. Everything attributed below
was read from its source on that date; line-level claims name the file.

What opencode does
------------------

1. A fixed summary *template*, not a prose instruction
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``packages/core/src/session/compaction.ts`` defines a
``SUMMARY_TEMPLATE`` and asks the model to "output exactly the Markdown
structure shown" with the order unchanged::

    ## Objective
    - [one or two brief sentences describing what the user is trying to accomplish]

    ## Important Details
    - [constraints/preferences, decisions and why, important facts/assumptions,
       exact context needed to continue, or "(none)"]

    ## Work State
    ### Completed
    - [finished work, verified facts, or changes made; otherwise "(none)"]
    ### Active
    - [current work, partial changes, or investigation state; otherwise "(none)"]
    ### Blocked
    - [blockers, failing commands, or unknowns; otherwise "(none)"]

    ## Next Move
    1. [immediate concrete action, or "(none)"]
    2. [next action if known, or "(none)"]

    ## Relevant Files
    - [file or directory path: why it matters, or "(none)"]

The attached rules are the interesting part:

- **Keep every section, even when empty.** The model cannot silently drop
  a category it did not consider — "Blocked", "Next Move" and "Relevant
  Files" are always present, at least as "(none)".
- **Terse bullets, not prose paragraphs.**
- **Preserve exact file paths, symbols, commands, error strings, URLs and
  identifiers verbatim.**
- **Do not mention the summary process or that context was compacted** —
  the resumed agent must not know (or narrate) that it was summarized.

Our `summary_prompt/0` (``Session.Compactor``) is a free-form paragraph
naming the same *kinds* of facts ("every file touched (exact paths);
every command/tool run …; numbers measured") but imposing no structure,
so the shape of the result is the model's choice. The template is a
different mechanism: it enumerates the categories so none is forgotten.

2. Summaries accumulate (rolling summary)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

When a summary already exists, opencode does **not** summarize a fresh
span from scratch. ``SUMMARY_UPDATE_INSTRUCTIONS`` tells the model to
*fold* the new conversation into the prior summary::

    Carry forward objectives, constraints, user directives, decisions,
    and parallel workstreams from the <prior-summary> even when the
    <conversation> does not mention them. Drop only what is finished and
    no longer needed. The <conversation> is more recent than the
    <prior-summary>. Where they conflict, the conversation wins: state
    the corrected fact and drop the old claim. Add new progress … Move
    completed work from "Active" to "Completed".

So the summary is a **carried-forward artifact**: a fact survives the
second and third compaction because it was carried into the new summary,
not because it happened to fall in the recently-summarized span. The
prior summary is explicitly "discarded after this: anything you do not
carry into the new summary is lost" — the model is told the stakes.

Our ADR 037 summarizes only the *new* span each time and replaces it with
a fresh summary. A fact recorded in the first summary of a session is not
guaranteed to be in the third: each compaction re-derives from the span
at hand. The review session that motivated ADR 037 compacted **three
times** (ADR 037, Context), which is exactly the case the rolling
approach is built for.

3. Prune: deletion without a model
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Before (and often instead of) summarizing, opencode **erases old tool
outputs and keeps the tool call** (``packages/opencode/src/session/compaction.ts``,
``prune``). A completed tool result is marked ``time.compacted`` and its
content is rendered later as ``[Old tool result content cleared]``; the
call — "which command ran" — stays. The walk is backwards and
deterministic:

- ``PRUNE_PROTECT = 40_000``: keep the most recent ~40k tokens of tool
  output untouched.
- ``PRUNE_MINIMUM = 20_000``: only prune if the candidate total exceeds
  20k tokens (below that it is not worth the churn).
- ``PRUNE_PROTECTED_TOOLS = ["skill"]``: never prune these.
- Stop at a summary boundary; the model's own turns are not erased.

This is the cheap middle ground between "keep everything" and "summarize
everything": large, disposable tool dumps (file contents, test logs) drop
out of the billed context while the *structure* of what was done
survives. It needs no provider call and cannot hallucinate. We have no
equivalent — every reduction we make goes through the summarizer.

4. Serialization: what the summarizer is even shown
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The summarizer does not see raw message structs. Each message is rendered
with an explicit tag (``serialize``): ``[User]:``, ``[Assistant]:``,
``[Assistant reasoning]:``, ``[Assistant tool call]: <tool>(<input>)``,
``[Tool result]: …``, ``[Tool error]: …``, ``[Shell]:``, ``[System
update]:``, ``[Synthetic context]:``. Tool output is truncated to
``TOOL_OUTPUT_MAX_CHARS = 2_000`` per result, and an already-erased result
renders as ``[Old tool result content cleared]``.

This is the same lesson ADR 037 learned independently: ``Compaction.render/1``
was changed to carry tool **names and arguments**, because an assistant
message with tool calls is text-empty and the old render dropped *which*
file was read and *which* command ran (ADR 037, Context §2a). The two
projects converged on the same fix.

5. Trigger and tail boundary
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- **Trigger** (``core/session/compaction.ts``, ``compactIfNeeded``): if
  ``estimate(system + messages + tools) <= context - max(output, buffer)``
  do nothing, else compact. ``DEFAULT_BUFFER = 20_000``. This is a
  pre-call, size-based decision, like our hard limit; opencode's
  ``isOverflow`` in ``packages/opencode/src/session/overflow.ts`` is the
  final guard.
- **Tail kept verbatim**: ``preserve_recent_tokens`` defaults to
  ``min(15_000, max(2_000, 25% of usable))``, overridable, with
  ``tail_turns`` for an exact turn count. ``DEFAULT_KEEP_TOKENS = 8_000``.
  The split is at **turn boundaries** (user messages), with an in-turn
  token-based split only when a single turn exceeds the budget.
- **Summary output is capped** at ``SUMMARY_OUTPUT_TOKENS = 4_096``.

6. Auto-continue after compaction
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

After an automatic compaction, opencode injects a synthetic user turn:
"Continue if you have next steps, or stop and ask for clarification if
you are unsure how to proceed." The agent resumes without waiting for the
human. We have nothing like this (ADR 037 leaves the next move to the
user), which is one reason a long turn that compacts mid-flight still
stops at the turn boundary.

How we compare
--------------

.. list-table::
   :header-rows: 1
   :widths: 26 37 37

   * - Concern
     - This harness (ADR 023/037)
     - opencode 1.18.33
   * - Summarizer instruction
     - free-form prose naming fact *kinds*
     - fixed Markdown template, all sections kept, exact-identifier rule
   * - Across repeated compactions
     - fresh span each time; earlier summary can be lost
     - rolling: prior summary carried forward, conversation wins conflicts
   * - Non-model reduction
     - none
     - ``prune``: erase old tool outputs, keep the call (~40k protect,
       20k minimum)
   * - Serialization
     - ``render/1`` with tool names + arguments (ADR 037 fix)
     - tagged lines, tool input JSON, 2k/result truncation
   * - Trigger
     - soft (idle, window-relative) + hard (pre-call reserve)
     - pre-call: below ``context - max(output, 20k)`` keep, else compact
   * - Tail
     - snap to complete exchange, min ~6 messages
     - turn boundaries, ``preserve_recent_tokens`` ~2k..15k / 25%
   * - Auto-continue
     - no (turn ends)
     - yes (synthetic "continue" user turn)

What we might adopt, and the cost
----------------------------------

Ordered by value per unit of change; none is decided here.

1. **Template + rolling summary (prompt-only).** *Adopted 2026-09-30
   (ADR 037 decision 5).* The ``SUMMARY_TEMPLATE`` sections and
   ``SUMMARY_UPDATE_INSTRUCTIONS`` translated directly into our
   ``Compaction.summary_prompt/2``: same provider, same call, a
   structured instruction and a carried-forward prior summary instead of
   a free-form one. It is the cheapest change with the largest expected
   effect, and it targets the exact failure we have (facts lost across a
   third compaction).

2. **A prune pass (small new mechanism).** Deterministic, no provider
   call, and it shrinks the context before the summarizer sees it, so it
   helps even when the summarizer would otherwise be skipped. It fits our
   split cleanly: ``Compaction`` already owns the message plumbing and
   ``Compactor`` the policy. The cost is a second thing that mutates the
   agent view, and it must respect the display view boundary (the display
   view is append-only and never touched — see :doc:`memory`). opencode
   marks the part (``time.compacted``) rather than dropping it, so the
   call survives; we would need the same "erase the body, keep the name"
   shape, which our message model can express (a tool-result message's
   content can be replaced while the message stays).

3. **Auto-continue (a UX decision).** It removes the human re-prompt after
   a mid-turn compaction, which is the friction we watched live. It also
   changes who decides when a turn ends — a real product decision, not an
   optimization.

Two things the comparison **does not** support, worth stating because
they are the questions we have actually been asking:

- **No agent-visible context usage.** opencode's injected reminders
  (``packages/opencode/src/session/reminders.ts``) are plan/build-mode
  switches; there is no block telling the model how full its window is or
  where compaction will fire. ADR 040 is, as far as this reading shows,
  not something the reference tool does.
- **No agent-triggered compaction.** There is no tool by which the agent
  compacts on its own; compaction is created by the runtime (``create`` /
  ``process`` in ``compaction.ts``), not called by the model.

So the "let the agent manage its own context" experiment (ADR 040) has no
off-the-shelf precedent to copy; the parts with precedent are the
summarizer prompt and prune.

References
----------

- ``packages/core/src/session/compaction.ts`` — ``SUMMARY_TEMPLATE``,
  ``SUMMARY_UPDATE_INSTRUCTIONS``, ``buildPrompt``, ``serialize``,
  ``settings``, ``compactIfNeeded``, ``compactAfterOverflow``.
- ``packages/opencode/src/session/compaction.ts`` — ``prune``
  (``PRUNE_PROTECT``/``PRUNE_MINIMUM``), ``serialize`` with tagged lines,
  ``TOOL_OUTPUT_MAX_CHARS``, auto-continue.
- ``packages/opencode/src/session/overflow.ts`` — ``isOverflow`` /
  ``usable``.
- ``packages/opencode/src/session/reminders.ts`` — injected reminders
  (plan/build mode), no usage block.
- Read 2026-09-30, opencode 1.18.33, ``anomalyco/opencode`` (MIT).
