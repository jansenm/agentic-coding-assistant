Memory and Sessions
===================

Agentic memory is *three* different problems that are often conflated.
Keeping them separate is the most important architectural decision in this
document.

1. Working context (short-term)
-------------------------------

The message history actually sent to the LLM on each call. It overflows
quickly, because tool outputs (file contents, test results) are large.
It is managed by **compaction**: old turns get summarized, recent turns
stay verbatim.

Compaction triggers at an **absolute** token threshold
(`compaction_trigger_tokens`, default 180k), not a percentage of the
model's window — the opencode lesson: a big window with a
percentage trigger compacts far too late, and per-turn cost scales
with context size, so late compaction burns quota at unheard speeds.
The threshold is visible in the sidebar ("compacts at 180.0k tok"),
and the session warns once at 80% of the trigger
("· context at 144k tokens — compaction at 180k will summarize
older messages") so it is never a silent surprise.

2. Session state (mid-term)
---------------------------

The durable, resumable unit of work. A *session* holds the full message
history, tool-call state and agent configuration as a serializable
snapshot that is written at lifecycle boundaries (after each turn, before
and after interruptions). A session that outlives a process restart is a
hard requirement for a coding assistant.

**Implemented** (:mod:`CodingAgent.Core.Session.Store`): a *store* is
**one SQLite database file** holding many sessions (ADR 020/023). The
context is now **per-message rows** in a ``messages`` table (each that
message's ``term_to_binary``), so appending a turn inserts rows rather
than rewriting the whole conversation; the ``sessions`` row holds the
rest of the state as a BLOB plus metadata columns (model, status,
scope_root, saved_at, size) so listing reads columns, never decodes a
state. Writes are an atomic transaction at every turn boundary (turn
complete, turn error, gate interruption, decision applied). The TUI session picker lists them and
``mix tui --resume <id>`` continues one — the model retains the full
previous context, verified live (a codeword given in one process was
answered from the resumed one). (The one-shot CLI ``mix agent`` was
retired 2026-09-20; the TUI is the only surface.)

.. note::
   ADR 020 (in progress) chose the SQLite engine and **one database per
   selectable store** (many sessions inside). The **display view now
   persists separately** (slice 3b-i): an append-only, session-keyed
   ``display`` table of plain text, so reasoning survives a resume and
   compaction cannot erase visible history (the two bugs below). The
   **agent view is now per-message rows too** (slice 3b-ii): the context
   is one ``messages`` table row per message, so appending a turn is one
   ``INSERT`` and compaction rewrites only the changed suffix rather than
   the whole context. The ``sessions.state`` BLOB keeps everything else
   (policy, pending calls, usage). Reasons: (1) the display view was
   reconstructed from the compaction-mutable agent view, so reasoning was
   lost on resume and compaction erased visible history — a violation of
   the dual-view pattern below; (2) cross-session search, aggregation and
   export are wanted and the blob could answer none of them; (3) the real
   pain in opencode was the missing verbs (R0), which this project
   addresses first-class. The ``Store`` API is unchanged by that ADR, so
   the two coexist.

Design points worth knowing:

- **Fail-closed loading**: corrupt bytes, wrong format version or a
  foreign payload error out — never a half-restored session.
- **The stored model wins on resume.** A session carries its own model
  as durable state; ``resume_opts/1`` passes the persisted ``state.model``
  through, so a resumed session is not silently reset to the current
  ``config.toml`` default (per-session continuity; a deliberately chosen
  model sticks). A fresh session follows the configured default. An idle
  model switch is persisted immediately — the same rule as an idle
  ``set_agent`` — so switching between turns and quitting does not
  resurrect the old model (this was a live bug: the menu showed the new
  model, the resumed session ran the old one).
- **Runtime-only fields do not resurrect**: subscribers are dropped,
  a saved ``:running``/``:error`` session resumes as ``:idle``
  (paused work, not a fake stream). ``:interrupted`` resumes as
  ``:interrupted`` — pending gate decisions survive a crash.
- **Atoms are restored without ``:safe``**: a saved session
  legitimately contains atoms the model's turn created (provider
  option keys, error tags) that a fresh VM has not; ``[:safe]``
  rejected those and broke resume. Session files are user-local
  (same trust domain as ``.env``), so atom-creation hardening is not
  this file's threat model; corruption resistance is.
- **Persistence failure never kills the session**: an unwritable disk
  logs a warning; the in-memory session keeps working.

How long is a stored session readable?
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Short answer: an OTP, Elixir, or 32→64-bit move does **not** make a saved
session unreadable. The realistic risk is *our own schema evolution*, and
that is what the guards below address.

The state BLOB is ``:erlang.term_to_binary/1`` — the **External Term
Format** (ETF), a stable, documented, platform-independent contract
(that is what "external" means). Measured facts:

- **Integers are size-dependent, not word-size-dependent.** ``255``
  encodes as ``SMALL_INTEGER_EXT`` (1 byte); ``65535`` as ``INTEGER_EXT``
  (fixed 4 bytes); ``2^31`` as a bignum. A 32-bit BEAM and a 64-bit BEAM
  write the *same bytes* for the same number.
- **Floats are IEEE-754**, a fixed 8-byte encoding.
- **The magic byte** is ``131`` (``VERSION_MAGIC``) followed by a format
  version; ``minor_version: 2`` (the default) uses ``ATOM_UTF8_EXT``.
- The compatibility guarantee is deliberately **backward**: a newer OTP
  reads a term written by an older one. This is why ``binary_to_term``
  can read decades-old Erlang binaries.

What *can* break, and why it is guarded:

- **Non-portable leaves**: a PID, reference, port or fun embedded in the
  term is node/VM-local — meaningless on another VM. Verified: a
  persisted ``%State{}`` contains **none** (``State.restore/1`` clears the
  runtime-only fields before a save). This is a property to keep and test,
  not an accident.
- **Atoms**: a BLOB containing an atom the target VM has not interned
  fails under ``[:safe]``. We therefore load without ``[:safe]`` (the 4a
  lesson) — the trust domain is the user's own store file.
- **Struct changes**: a field renamed or removed by a later version is
  healed by ``State.restore/1`` (fill missing fields with defaults;
  reject unknown ones gracefully), or fails closed.
- **Format-version bump**: the leading ``@format_version`` makes an
  incompatible format **fail closed** (an error, never a half-restored
  state) rather than load garbage.

So the durability promise is: *the encoding is stable across platforms and
runtime versions; the schema is the thing we evolve, deliberately, behind
a version byte and a healing loader.*

3. Long-term memory (cross-session)
-----------------------------------

Knowledge that survives across sessions: project conventions, decisions,
lessons the agent learned. The pragmatic implementation writes Markdown
files back into the project (an ``AGENTS.md``-style pattern); vector
storage is an optional later addition.

**First implementation in slice 4c**: an ``AGENTS.md`` at the scope
root is read once at session start and appended to the system prompt
(64 KiB cap, truncated with a warning; missing file is the normal
case). The knowledge lives in *your* repository — versioned, greppable,
editable with the same tools the agent uses — and the loader is a few
dozen lines, because writing knowledge down as files is the whole
point; no exotic memory system needed.

Session storage principles
--------------------------

Design commitments for the session store, written down after seeing
what we did *not* want (opencode's storage measured on a dev machine:
a 113 MB SQLite DB, sessions keyed to the directory they were opened
in, project deletion leaving orphaned rows, cleanup = schema
archaeology). Revisit any of these only with a new ADR.

.. note::
   These principles were written against opencode's concrete failure
   modes, not against databases as such. ADR 020 revisits the *format*
   (one SQLite database per selectable store) and, crucially,
   promotes the missing concern to the lead requirement: **R0 — session
   management is a first-class product surface.** The opencode objection
   was an API objection (a hidden directory as a password; SQL as the
   only lens), not an engine objection. The principles below are
   unchanged in intent; principle 2's "no opaque database blob" is
   refined to "one *store* = one portable unit = one ``rm``" (the
   per-*session* file split was revisited on 2026-09-20 — see ADR 020),
   and the size guard in principle 4 is now concrete.

0. **The verbs are the product (R0).** A store without the operations
   to list, filter, search, size, delete (by id, age, size or
   directory), export and import is unusable regardless of its engine.
   The UI surface ships with — or before — the engine change.

1. **Portability over project-binding.** A session belongs to itself;
   the repo scope root is *data inside the session*, not the storage
   key. Moving/renaming a directory orphans nothing; resuming from
   elsewhere is possible (with the scope as recorded). A *store* is a
   database file the user selects (ADR 020, R16).

2. **One *store* = one portable unit = one ``rm``.** Cleanup stays
   discoverable via the TUI session picker, never schema archaeology.
   The store is the file you ``rm``/``du``; deleting one *session* is a
   transactional ``DELETE`` and single-session portability is
   ``--export``. (An earlier draft put one session per file; the
   aggregated-per-store choice is recorded in ADR 020, with its costs.)

3. **Lifecycle commands are first-class verbs.** Listing is not
   enough: deleting, pruning (age/size), deleting by directory and
   exporting belong in the UI and CLI surface, so cleanup never depends
   on undocumented files.

4. **Size honesty.** Listing shows each session's footprint and ``du``
   is a truthful answer to "how much session data do I have"; aggregate
   stores hide growth until the number is embarrassing.

5. **Retention is a decision, not an accident.** Any cap/TTL policy
   gets an ADR and a CLI verb; silent accumulation is the failure mode
   this list exists to prevent. A loud, configurable size *warning* is
   preferred over silent deletion.

Compaction (short-term tier)
----------------------------

**Implemented in slice 4b** — the operation is split by concern:

- :mod:`CodingAgent.Core.Compaction` — pure message plumbing: the plan
  (which span is summarized, everything except the last 6 messages),
  ``apply`` (replace the span with the synthetic summary message) and
  ``render`` (span → text for the summarizer model). No policy, no I/O.
- :mod:`CodingAgent.Core.Session.Compactor` — the policy and the one
  provider call: the trigger decision, the wall-clock budget, the
  failure backoff, the UI broadcast.

Before every LLM call the session asks the Compactor. The trigger is
the provider's own ``last_input_tokens`` against the **absolute**
threshold (``compaction_trigger_tokens``, default 180k) — chars
estimates drift, the provider's count is ground truth. Chars are only
the FIRST-TURN fallback (no usage data yet); known-but-below usage
never compacts (the chars-only trigger fired at ~20k tokens on fat
contexts and stalled every turn behind a minutes-long summarize call —
found live). The session warns once at 80% of the trigger
("· context at 144k tokens — compaction at 180k will summarize
older messages") so it is never a silent surprise.

**One reader of the trigger policy.** ``Compactor.trigger/0`` and
``Compactor.warn_threshold/0`` are the only code that read
``compaction_trigger_tokens`` or the 80% fraction; the sidebar renders
exactly what the decision uses. A resumed session must carry the
persisted ``usage`` (and ``compaction_warned`` / ``compaction_backoff``)
into its live state — otherwise ``last_input_tokens`` restarts at 0 and
a just-resumed context takes the chars fallback and compacts on the
first command (found live).

The summarize call is a non-streaming round trip on the same model,
executed in a task under
:mod:`CodingAgent.Core.Session.Compactor.TaskSupervisor` — **never
linked to the session process** (a crash inside the provider stack
must degrade, not kill the turn) — and bounded twice: a receive
(inactivity) timeout inside the call and a hard wall-clock budget
(300 s) around it, because a slow cloud model can hold the call open
indefinitely (found live — compaction hung past 2 minutes mid-turn;
GLM on an 80K-char context takes minutes, so the budgets must be
generous or every large compaction is abandoned).
Every exit is handled — result, error, crash, budget — and failure
degrades: the full (oversized) context is kept and compaction backs
off for the next 3 turns instead of retrying every turn (2+ minutes
of dead silence before every real turn, found live).

Design notes:

- **The plan is decided once and passed through** — the summarize task
  re-plans nothing; the span it summarizes is exactly the span the
  trigger decided on (a token-triggered decision re-planned on chars
  once summarized a different span — or none, which crashed the task).
- **Never compact the recent tail** — it is what the model reasons
  over next; losing it to summary would blind it mid-task.
- **Failure degrades, never errors**: if the summary call fails, the
  full (oversized) context is kept and the turn proceeds.
- **Compaction rewrites the agent view only**: it mutates the agent
  view and nothing else. The display view is the immutable record
  compaction must never touch — the principles above and the mermaid
  diagram in this page fix that boundary. The display view is now
  persisted separately (ADR 020 slice 3b-i), so compaction cannot erase
  visible history and reasoning survives a resume; a test asserts the
  display view is byte-identical across a compaction-like rewrite of the
  agent view.
- Verified live: a 238k-char tool result triggered compaction on the
  next call, and the model still answered a question about the
  compacted-away content correctly from the summary.

The dual-view pattern
---------------------

Every conversation has **two views that are not the same content in a
different encoding**. This is the single most misunderstood point of this
document, so it is spelled out.

- **Agent view** — what the LLM sees. The message history sent on the
  next request. Compaction mutates it.
- **Display view** — what the user sees. The rendered transcript.
  Append-only; never touched by compaction.

They overlap only on *user*, *assistant* and *tool-result* messages.
Everything else differs — in content, in mutability, in shape and in
purpose:

.. list-table::
   :header-rows: 1
   :widths: 15 45 40

   * - Aspect
     - Agent view
     - Display view
   * - Contains
     - system prompt, **compaction summary**
     - reasoning, **info notes**
   * - Missing
     - reasoning, info notes
     - nothing user-visible
   * - Mutability
     - compaction ``DELETE``/replaces a span
     - append-only, immutable
   * - Shape
     - must be **wire-valid** (tool pairs, role order, content parts)
     - rendered order, thoughts interleaved with the text
   * - Encoding
     - exact ``ReqLLM`` structs
     - plain text (what was on screen)
   * - Purpose
     - the next provider request
     - the honest, resumable history

Two consequences fall directly out of conflating them, both observed
live:

1. **Reasoning is lost on resume.** ``:reasoning_delta`` is broadcast to
   the UI and *discarded*; nothing appends it to the agent view, because
   the agent view is the wire format and reasoning is not part of it. A
   display view reconstructed from the agent view therefore cannot show
   the thinking after a resume.
2. **Compaction erases visible history.** The agent view *is* mutated by
   compaction (a summary replaces the old span). Reconstructing the
   display from it shows the lossy result — exactly what an immutable
   transcript must prevent.

The fix is structural: persist the two views separately (ADR 020). The
agent view stays wire-exact and compactable; the display view is written
from the same loop events as an append-only text record. Because the
display view is *text by nature* — it is what was rendered — it is also
the one that can be searched (SQL ``LIKE`` now, FTS5 later if a store-wide
search proves slow), while the agent view is never grepped.

.. mermaid::

   flowchart LR
       E[Loop events] --> A[(Agent state / LLM view)]
       E --> D[(Display transcript / UI)]
       A --> S[(Session store: agent view)]
       D --> P[(Session store: display view, append-only)]
       C[Compaction] -. mutates .-> A
       C -. never touches .-> D