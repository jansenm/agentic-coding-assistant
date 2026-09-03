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

2. Session state (mid-term)
---------------------------

The durable, resumable unit of work. A *session* holds the full message
history, tool-call state and agent configuration as a serializable
snapshot that is written at lifecycle boundaries (after each turn, before
and after interruptions). A session that outlives a process restart is a
hard requirement for a coding assistant.

**Implemented in slice 4a** (:mod:`CodingAgent.Core.Session.Store`):
the full state is one ``term_to_binary`` blob under
``~/.local/state/coding_agent/sessions/<id>.session``, written
atomically at every turn boundary (turn complete, turn error, gate
interruption, decision applied). ``mix agent --sessions`` lists them,
``mix agent --resume <id>`` continues one — the model retains the full
previous context, verified live (a codeword given in one process was
answered from the resumed one).

Design points worth knowing:

- **Fail-closed loading**: corrupt bytes, wrong format version or a
  foreign payload error out — never a half-restored session.
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

3. Long-term memory (cross-session)
-----------------------------------

Knowledge that survives across sessions: project conventions, decisions,
lessons the agent learned. The pragmatic implementation writes Markdown
files back into the project (an ``AGENTS.md``-style pattern); vector
storage is an optional later addition.

Session storage principles
--------------------------

Design commitments for the session store, written down after seeing
what we did *not* want (opencode's storage measured on a dev machine:
a 113 MB SQLite DB, sessions keyed to the directory they were opened
in, project deletion leaving orphaned rows, cleanup = schema
archaeology). Revisit any of these only with a new ADR:

1. **Portability over project-binding.** A session belongs to itself;
   the repo scope root is *data inside the session*, not the storage
   key. Moving/renaming a directory orphans nothing; resuming from
   elsewhere is possible (with the scope as recorded).

2. **One session = one file = one ``rm``.** No opaque database blob.
   Cleanup is a file operation, discoverable via ``--sessions``
   (which must print the file paths), never schema archaeology.

3. **Lifecycle commands are first-class verbs.** Listing is not
   enough: deleting, pruning (age/size) and exporting belong in the
   CLI surface — ``--sessions`` will grow a delete/prune action
   before 4b lands, so cleanup never depends on undocumented files.

4. **Size honesty.** The per-file format keeps ``du`` a truthful
   answer to "how much session data do I have"; aggregate stores hide
   growth until the number is embarrassing.

5. **Retention is a decision, not an accident.** Any cap/TTL policy
   gets an ADR and a CLI verb; silent accumulation is the failure
   mode this list exists to prevent.

Compaction (short-term tier)
----------------------------

**Implemented in slice 4b** (:mod:`CodingAgent.Core.Compaction`):
before every LLM call the session checks the context volume (chars
across message text — a cheap proxy, no tokenizer). Past the 80k
threshold, the *old* span (everything except the last 6 messages) is
summarized by the model itself — one dedicated call, no tools — and
replaced by a synthetic summary message; the recent tail stays
verbatim. The compacted state persists immediately.

Design notes:

- **Never compact the recent tail** — it is what the model reasons
  over next; losing it to summary would blind it mid-task.
- **Failure degrades, never errors**: if the summary call fails, the
  full (oversized) context is kept and the turn proceeds; compaction
  retries on the next call.
- **v1 rewrites the agent view only**: the CLI transcript is
  ephemeral today. When the dual-view transcript lands (phase 5), the
  display view is the immutable record compaction must never touch —
  the principles above and the mermaid diagram in this page already
  fix that boundary.
- Verified live: a 238k-char tool result triggered compaction on the
  next call, and the model still answered a question about the
  compacted-away content correctly from the summary.

The dual-view pattern
---------------------

Keep two views of every conversation:

- **Agent view** – what the LLM sees. Compact, compaction-friendly.
- **Display view** – what the user sees. The full, immutable transcript.

Both are written from the same events; compaction of the agent view never
destroys user-visible history.

.. mermaid::

   flowchart LR
       E[Loop events] --> A[(Agent state / LLM view)]
       E --> D[(Display transcript / UI)]
       A --> S[(Session snapshot store)]
       D --> P[(Persisted display messages)]