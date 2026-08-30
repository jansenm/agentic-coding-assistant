The Agent Loop
==============

The heart of the system is a small, explicit loop:

.. mermaid::

   flowchart TD
       A[User prompt] --> B[Build context from memory]
       B --> C[Call LLM]
       C --> D{Tool calls in response?}
       D -- no --> E[Answer the user]
       D -- yes --> F[HITL approval needed?]
       F -- yes --> G[Pause, ask user]
       G --> H[Execute approved tools]
       F -- no --> H
       H --> B

Key properties
--------------

- **Everything is data.** A message, a tool call, a tool result and an
  approval decision are plain structs — serializable, so a session can be
  saved and resumed at any point in the loop.
- **The loop is a process.** One session runs in one supervised OTP
  process; a crash never loses the persisted state.
- **Interruption is a state, not an exception.** Human-in-the-loop approval
  is modelled as a saved, resumable state of the loop.