:orphan:

The question tool: a channel to ask the human mid-turn
======================================================

.. adr::
   :id: 027
   :status: Accepted
   :date: 2026-09-23
   :tags: sessions, agents, tools, prompts

.. note::
   Accepted and implemented 2026-09-23. Answers T6 in the
   ``code_review.md`` "rival opencode" list. Adds a ``question`` tool: the
   model can ask the human one or more multiple-choice questions
   mid-turn, the session pauses, and the answers arrive as the tool's
   result. Interactive drivers show a wizard; a driver that cannot answer
   gets a synthetic "unavailable" result so the turn never hangs.

   **Implemented.** ``Core.Tools.Question`` (a raw JSON-Schema map for the
   nested ``questions`` array; the callback is a loud safety net, never
   executed). Registered in the read-only class so every agent including
   ``plan`` carries it. ``Session.run_round/2`` intercepts a question
   call, holds the WHOLE round in ``State.question_pause``, and broadcasts
   ``{:status_changed, :question_asked, %{questions: questions}}``;
   ``Session.answer_question/2`` runs the held round with the formatted
   results (opencode's ``User has answered your questions: "q"="a".``
   shape, ``Unanswered`` for a blank). A malformed question returns an
   in-round error instead of pausing. The TUI renders a one-question-at-a-
   time wizard (``question_widgets/2``, ``question_special/2``,
   ``question_text/2``), digits toggle options, ``0`` is free text,
   enter confirms, esc skips.

Context
-------

A dogfooding incident exposed the gap. The ``build`` agent was asked to
fix the glob tool and quietly grew the task into a cross-cutting refactor
of glob, grep and ``Containment`` (772 uncommitted lines across six
files, 8 "Now let me…" pivots in one turn). The scope change was probably
*correct* — the two search tools do share a hidden-file rule — but it was
decided unilaterally. The prompt already says "keep changes scoped to the
task"; that did not help, because the missing piece is not wording: there
is **no way for the model to ask a question and get an answer**. Its only
options were to guess or to spin.

Both failure modes of the current harness trace to this: scope creep (the
model guesses that widening is wanted) and the "five minutes in circles"
loop (the model guesses at what the user meant). ADR 026 catches the
symptom; this ADR removes a cause.

opencode has this as a built-in tool. From its source
(``packages/opencode/src/tool/question.ts`` and ``src/question/index.ts``,
MIT, 2026-09-23):

.. code-block:: ts

   Parameters = Schema.Struct({
     questions: Schema.mutable(Schema.Array(Question.Prompt)),
   })

   // execute:
   const answers = yield* question.ask({ sessionID, questions, tool })
   const formatted = questions
     .map((q, i) => `"${q.question}"="${answers[i]?.join(", ") ?? "Unanswered"}"`)
     .join(", ")
   return { output: `User has answered your questions: ${formatted}. ...` }

A question has a ``question`` text, a ``header``, ``options``
(``label``/``description``), and ``multiple``. With ``custom`` enabled a
"Type your own answer" option is added automatically; recommended options
go first with "(Recommended)" appended. The session stores the request
and blocks on it until a reply or reject arrives.

Decision
--------

**1. A ``question`` tool with structured options.** The tool takes
``questions: [{question, header?, options: [{label, description?}],
multiple?}]``. It is registered in the read-only class and available to
every agent — asking is read-only, and the plan agent needs it as much as
the build agent.

**2. The session pauses; the round is held.** A round containing a
``question`` call is not executed. The session parks at ``:interrupted``
with ``State.question_pause`` holding the whole round and the parsed
questions, and broadcasts
``{:status_changed, :question_asked, %{questions: questions}}``. Holding
the *whole* round (not just the question) keeps the exchange atomic: a
``[read_file, question]`` round runs the read only after the answer.

**3. The answer is the tool result.** ``Session.answer_question/2`` takes
one answer list per question (``[[label, …], …]``), clears the pause, and
runs the held round with the question results pre-known. The result text
follows opencode's shape: ``User has answered your questions:
"q"="a, b". You can now continue with the user's answers in mind.`` An
unanswered question renders as ``Unanswered``.

**4. A non-interactive driver gets an "unavailable" result.** With no one
to ask, the question is answered synthetically: the human is not
available, proceed with best judgment or stop and ask plainly. The rule
from ADR 025/026 holds: the session never hangs on a question nobody can
answer.

**5. The ``question`` tool's callback is a safety net, not an
implementation.** Tools execute through ``ToolRunner``; a question cannot
block there. The gate intercepts question calls before execution, and the
callback returns a loud error ("handled by the session, not executed") so
a call that ever reaches execution is a visible bug, not a deadlock.

Consequences
------------

- The model gains a way to resolve ambiguity instead of guessing — the
  direct fix for the scope-creep incident and a cause of loops.
- The pause reuses the machinery ADR 025/026 built (parked round,
  ``:interrupted``, durable pause, a driver decision verb), so there is
  no new turn-loop shape.
- ``question_pause`` is durable: a resume re-offers the dialog.
- A ``decide/2`` against a question pause is refused, keeping the four
  ``:interrupted`` reasons (approval, budget, doom, question) distinct.
- The tool is available to read-only agents (the plan agent) by design;
  ADR 017's "a subagent may not ask a primary" rule is not yet relevant
  (subagents are unimplemented) and is left to the subagent work.
- opencode's ``custom`` option (a free-text answer) is included; our first
  UI exposes it with a text mode in the dialog.

Open questions
--------------

1. Should the dialog support answering several questions at once (a form)
   or one at a time (a wizard)? The first implementation is a wizard
   (one question per screen) — simpler keys, clear progress — but a form
   is fewer keystrokes when there are several short questions.
2. Should ``question`` calls count against the tool-round budget? Currently
   a question round is held before the budget check, so it does not; a
   human interaction is not a provider round.
3. opencode gates the tool behind a client flag ("app"/"cli"/"desktop").
   We ship it always; if it proves noisy, a config switch is the natural
   control (the ADR 024 calibration surface could also tune when the model
   reaches for it).
