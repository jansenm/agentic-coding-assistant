.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

System Overview
===============

The Agentic Coding Harness is a terminal-based coding assistant built in
Elixir. Its guiding constraints are *trust* and *auditability*: the whole
system must compile from source with nothing but Erlang/Elixir installed,
with a dependency tree small enough to audit by hand.

.. mermaid::

   graph TD
       UI[TUI driver] <--> Core[Agent Core / Session]
       Core --> LLM[LLM client]
       Core --> Tools[Tool subsystem]
       Tools --> FS[Filesystem]
       Tools --> Shell[Shell]
       Core --> Pers[Session persistence]

Components
----------

- **Agent core** – owns the conversation loop: call the LLM, inspect the
  response, execute tool calls, repeat.
- **Session** – the durable unit of work: message history, agent state and
  persisted snapshots.
- **Memory** – working context, session state and long-term memory are
  separate concerns (see :doc:`memory`).
- **Tools** – sandboxed capabilities the LLM can invoke: file operations,
  shell execution, later MCP.
- **UI driver** – a thin terminal UI; the core is UI-agnostic so a web
  front-end stays possible.