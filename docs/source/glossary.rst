Glossary
========

.. glossary::

   Agent loop
      The core cycle: build context, call the LLM, execute tool calls from
      the response, append results, repeat until the model produces a final
      answer.

   Working context
      The message history sent to the LLM on each call; subject to
      compaction.

   Session
      A durable unit of agent work: full history, agent state and
      persisted snapshots; runs in one supervised OTP process.

   Compaction
      Summarizing/truncating old turns in the working context while keeping
      recent turns verbatim.

   HITL (human-in-the-loop)
      Pausing an agent before executing sensitive tool calls and resuming
      after human approval (allow / edit / reject).

   Dual-view pattern
      Keeping the LLM-facing compact history separate from the immutable,
      user-facing transcript.

   MCP (Model Context Protocol)
      Standard protocol for connecting agents to external tools and
      resources; planned as a later tool subsystem.