Technology Stack
================

The full stack is decided (ADRs 002–006):

- **Runtime**: Elixir/OTP — pure-Elixir dependency tree, ``mix release``
  builds (ADR 002)
- **Agent loop**: hand-rolled on a thin client; no Sagents/Jido (ADR 003)
- **LLM client**: ``req_llm`` (ADR 005)
- **Terminal UI**: hand-rolled components on ``ex_termbox`` (ADR 004)
- **Terminal input**: readline-style editing on ex_termbox events (ADR 006)

Rationale highlights are in the ADRs; the short version: dependency count
is treated as a security metric, protocol plumbing delegates to
battle-tested libraries (req, ex_termbox), and all domain logic — agent
loop, HITL, memory, tools — is owned code.

The protocols this stack sits inside — and which of them the harness
speaks, plans to speak, or deliberately does not — are mapped in
:doc:`agentic-ecosystem`.

Fixed by project constraints
----------------------------

- **Language / runtime**: Elixir on the BEAM — pure-Elixir dependency tree,
  reproducible ``mix release`` builds, no bootstrap compilers or binaries we
  have to trust blindly.
- **Supervision**: every session is a supervised OTP process.

Still open
----------

- Persistence: Ecto + SQLite vs. plain file snapshots (ADR when the
  session model is implemented)