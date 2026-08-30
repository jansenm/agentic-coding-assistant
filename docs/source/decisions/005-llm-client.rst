:orphan:

LLM client layer: req_llm
=========================

.. adr::
   :id: 005
   :status: Accepted
   :date: 2026-08-29
   :tags: stack, llm

Context
-------

ADR 003 decided the agent loop is hand-rolled, which requires a thin,
provider-agnostic HTTP client for LLM APIs. Candidates:

- **LangChain** (13.7k downloads/week, 1196 stars, active): mature, but
  its mandatory dependency set includes **ecto** and **gettext** — a
  database-changes layer and an i18n layer under a terminal application.
  Violates the dependency-minimality constraint (ADR 002) without
  providing anything the hand-rolled loop needs.
- **req_llm** (27k downloads/week, active, v1.x): spec-first thin client
  (provider coverage generated from the Anthropic/OpenAI specifications).
  Runtime deps: ~10, all small, well-known libraries (``req``, ``jason``,
  ``nimble_options``, ``zoi``). Provides streaming (SSE), tool-calling,
  provider specs, and a model registry.

Decision
--------

**req_llm** is the LLM client layer. The agent loop, HITL interrupts,
memory/compaction and persistence are built on top of it.

Consequences
------------

- Provider support is inherited from req_llm's spec coverage; adding a
  provider is a config change, not new protocol code.
- The trusted code below the agent loop shrinks to: req_llm (~10 deps),
  ex_termbox (one C file, ADR 004), and the Erlang/OTP standard library.
- Streamed responses and tool calls arrive as plain data; the loop owns
  all agent semantics.