:orphan:

Turn budget: the round limit degrades by wrap-up, not failure
=============================================================

.. adr::
   :id: 025
   :status: Accepted
   :date: 2026-09-23
   :tags: sessions, agents, tools, prompts

.. note::
   Accepted and implemented 2026-09-23. Answers T2 and the ``max_turns``
   half of T3 in the ``code_review.md`` "rival opencode" list. Decides
   that reaching the per-turn tool-round budget never fails the turn:
   an **interactive** driver is asked to *continue* (another full budget)
   or *stop* (a summarizing wrap-up), and a driver that cannot answer
   gets the wrap-up automatically. ``maxTurns`` is the per-agent budget;
   the global default has a ``config.toml`` knob. The pattern-based
   doom-loop guard (T2's detection half) remains open; this makes the
   numeric cap a safe backstop for it.

   **Implemented.** ``State.tool_budget/1`` resolves an agent's
   ``maxTurns`` over the session value over the app default;
   ``Config.max_tool_rounds/1`` reads ``max_tool_rounds`` from the layered
   ``config.toml``; the session resolves and stores it at init. At the
   budget ``gate_tools/2`` either (a) pauses the session ``:interrupted``
   with ``State.budget_pause`` holding the tripped round and broadcasts
   ``{:status_changed, :budget_reached, %{budget: n}}`` when the driver is
   interactive, or (b) wraps up. ``Session.budget_decision/2`` answers the
   pause: ``:continue`` resets the counter and runs the held round,
   ``:stop`` discards it and wraps up. The TUI renders a
   ``TOOL BUDGET`` panel (``budget_widgets/2``) and routes y/n
   (``handle_budget_key/2``). ``Prompt.wrap_up/0`` is the wrap-up
   instruction; the final call withholds tools via ``wire_request/2``.
   ``interactive`` is session state, not persisted; the durable
   ``budget_pause`` survives a resume so the dialog re-offers.

   **Two recorded divergences from opencode.** (1) opencode appends its
   ``MAX_STEPS_PROMPT`` as an *assistant prefill* and does **not** actually
   withhold tools; we append a user message (the ``Compaction.apply/2``
   shape) and do withhold them (``tools: []``, which `ReqLLM` treats as
   explicit "no tools", ``Context.persist_tools/2``). (2) opencode's
   default is ``Infinity`` with a single auto-stop; we keep a default
   backstop and add a continue affordance on top.

Context
-------

The harness caps a single turn at ``@default_max_tool_rounds 100``
(``config.ex:34``), enforced at the entry to every tool round in
``gate_tools/2`` (``session.ex:1053``). A "round" is one assistant
response that contains tool calls; the counter is **per turn** — it
resets when the next user prompt arrives (``session.ex:847``) — so the
budget is 100 tool exchanges for one prompt. The model runs into it
"quite often" in live use.

Two properties of the trip are wrong, and a third is a lie:

**1. The limit fails the turn instead of ending it.** On reaching the
budget, ``gate_tools/2`` calls ``fail_turn/2`` (``session.ex:1064``):
status becomes ``:error``, ``last_error`` is set, and the transcript
says "ask it to continue for another budget". The round's calls are
**not executed and not answered**. The user is left with a dead turn and
no account of what the agent had done.

**2. The budget is unreachable from configuration.** It is read only
through ``Application.get_env`` (``Config.max_tool_rounds/0``); nothing
in ``config.toml`` or the agent frontmatter can change it. The
documented ``maxTurns`` field is parsed into ``Core.Agent``
(``agent.ex:168``, ``frontmatter.ex:174``) and **used nowhere** —
verified by grep; ``temperature`` was the same and ADR 024 wired it.
A documented field that does nothing is a lie in the docs.

**3. The cap conflates two different failures.** A legitimate long task
(the comment at ``session.ex:70-77`` records a review that burned 25
rounds doing one small grep at a time) and a genuine runaway loop (the
"five minutes in circles" failure mode) hit the same counter. A count
cannot tell them apart; only seeing the *repetition* can.

What opencode does
------------------

Reading opencode's source (``packages/opencode/src/session/prompt.ts``
and ``packages/core/src/session/runner/max-steps.ts``, MIT, 2026-09-23)
settles the design question the user raised — "I assume opencode does
not have it":

- **No default cap.** The loop uses ``const maxSteps = agent.steps ??
  Infinity``. A budget exists only when an agent sets ``steps`` in its
  definition.
- **When a budget IS reached, the turn does not fail.** opencode injects
  ``MAX_STEPS_PROMPT``: "The maximum number of steps allowed for this
  task has been reached. Tools are disabled until next user input.
  Respond with text only." It then requires the model to state that the
  maximum was reached, summarize work done, list what remains, and
  recommend next steps — and it *breaks the loop cleanly* with that
  text as the final assistant message.
- **Runaway loops are caught by pattern, separately.** opencode's
  ``doom_loop`` permission (default ``ask``) detects a repeated tool
  call and interrupts it; the count and the pattern are different
  controls.

The lesson is that the count is a **backstop**, never the primary
control, and that hitting it is a *communication* event, not an error.

Verified non-issue (recorded so it is not re-investigated)
----------------------------------------------------------

A suspected latent bug — that the fail-hard path leaves the context with
an assistant ``tool_calls`` message and no matching tool results (a
wire-invalid state strict OpenAI-compatible backends reject) — is
**not** present. The assistant tool-call message is appended only in
``complete_round/3`` (``session.ex:1136``), which the limit branch
skips before constructing. The limit path leaves the context untouched
and valid. This matters for the decision below: because the round's
calls never entered the context, discarding them is safe.

Decision
--------

**1. Reaching the budget never fails the turn. An interactive driver is
asked; others get a wrap-up.** When ``gate_tools/2`` finds
``tool_rounds >= budget``:

- if the driver is **interactive**, the session parks at
  ``:interrupted`` (``State.budget_pause`` holds the tripped round) and
  broadcasts ``{:status_changed, :budget_reached, %{budget: n}}``. The
  question is *continue* (another full budget, running exactly the held
  round) or *stop*;
- otherwise (headless, a test), it **wraps up**: the round's calls are
  **discarded** (never executed, never appended); a synthetic wrap-up
  instruction (``Prompt.wrap_up/0``) is appended, in the spirit of
  opencode's ``MAX_STEPS_PROMPT`` (the budget is reached, no further tools
  are available this turn, respond with a text summary of what was done,
  what remains, and what to do next); **one** final provider call is made
  with **tools withheld**; and the resulting text becomes the turn's
  answer. Status ends ``:idle`` (not ``:error``), ``last_error`` is not
  set.

*Stop* from the dialog produces the same wrap-up. The next user prompt
starts a fresh turn with a fresh budget. The extra call is bounded at one
per wrap-up.

**2. ``maxTurns`` becomes the per-agent budget; the global default is a
``config.toml`` knob.** An agent definition's ``maxTurns`` overrides the
global default for turns run by that agent. The global default
(``@default_max_tool_rounds``) stays as the fallback and is exposed in
the layered ``config.toml`` (project over global), the same pattern as
``model`` and ``reasoning_effort``. An unset ``maxTurns`` means "use the
global default", **not** infinity: we keep a backstop by default where
opencode has none. Raising or lowering it is then a user action, not a
recompile.

**3. The count is documented as a backstop, and ADR 017's honoured-field
list is corrected.** ``max_turns`` moves from "parsed but unused" to
"honoured". The pattern-based guard (repeated identical calls, T2's
detection half) is recorded here as the intended primary control and
designed separately; this ADR does **not** decide its threshold or its
steering text.

Consequences
------------

- A turn that reaches the budget yields a usable status report and an
  ``:idle`` session, instead of an ``:error`` and a dead turn. An
  interactive user can also grant another budget with one key.
- The budget is tunable per agent and per project without recompiling,
  and can be raised safely because the trip is graceful.
- Reusing the existing pause machinery keeps the change contained: no new
  context shape, no dangling tool call, no change to ``complete_round``.
- One extra provider call is spent when the budget trips (the wrap-up), or
  none when the user continues. Bounded, and strictly more useful than the
  old zero-output failure.
- The wrap-up relies on the model following a tool-less instruction. A
  model that emits a tool call anyway (our client offers none, so this
  should be impossible at the wire) would need a guard; recorded as an
  open question rather than assumed.
- ``max_turns`` was the last of ADR 024's T3 fields; with
  ``temperature`` (ADR 024) and ``max_turns`` (here) wired, only
  ``hidden``'s consumption remained to be checked — wired by ADR 029
  alongside ``reasoning_effort`` and the ``mode: all`` selection rule.

Open questions
--------------

1. Is the wrap-up a synthetic **user** message or a system-role
   instruction? **Decided during implementation: a user message** — the
   same shape as ``Compaction.apply/2``, which also injects a synthetic
   instruction. (opencode uses an assistant prefill; we diverge, recorded
   above.)
2. Should a wrap-up call offer a **reduced** tool set (e.g. allow
   nothing but keep the schema valid) or **no** tools key at all? The
   choice affects providers that require a non-empty tool list.
   **Decided: ``tools: []``**, which `ReqLLM` treats as an explicit empty
   set. A provider that rejects an empty list would surface as a wrap-up
   call error; none has been observed.
3. Does the doom-loop guard's threshold live per model family (the
   ADR 024 calibration surface) or remain a single global constant?
4. Should the user be able to grant "another budget" without answering
   the dialog? **Decided: yes — the ``continue`` affordance** (y at the
   budget prompt). It grants another full budget and runs the held round.
