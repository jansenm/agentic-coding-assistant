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