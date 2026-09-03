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