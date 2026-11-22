.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

Agent framework: hand-rolled loop on a thin LLM client
=========================================================

.. adr::
   :id: 003
   :status: Accepted
   :date: 2026-08-29
   :tags: stack, agent

Context
-------

Three candidate stacks exist in the Elixir ecosystem:

- **Sagents** (on top of LangChain): conversation-centric agent GenServers
  with human-in-the-loop interrupts, session persistence, subagents and
  first-class Phoenix integration. Newest and most feature-complete for
  this exact use case, but 0.x (API churn risk) and the largest dependency
  tree.
- **Jido** (+ ``jido_ai``/``req_llm``): general OTP-native agent runtime
  (agents/actions/signals/directives). Lighter and more general; HITL and
  session persistence would be hand-rolled.
- **Hand-rolled agent loop on a thin LLM client** (``req_llm`` or
  LangChain): minimal dependencies, full ownership of every line; the most
  implementation work (HITL, compaction, persistence are our code).

The project's guiding constraint is auditability and a minimal trusted
dependency tree (see :doc:`002-elixir-beam`).

Decision
--------

**(2026-08-29, Accepted.)** Hand-roll the agent loop on a thin LLM client.
No agent framework (Sagents, Jido) is used. The client layer — the one
remaining sub-decision — is settled in :doc:`005-llm-client` (req_llm).

The deciding arguments, against this project's specific risk profile:

1. *Frameworks are battle-tested for reliability, not for this domain's
   security surface.* The exploitable parts of a coding agent are prompt
   injection via file contents, path traversal in file tools, shell
   quoting and HITL bypasses — young, novel code in every current
   framework, not decades-reviewed plumbing.
2. *Asymmetric failure modes.* Own bugs are adversary-independent,
   test-reachable and fixable in place; supply-chain compromise is
   adversary-timed, invisible until detonation, and survives the
   install-time audit. Rolling our own converts permanent,
   adversary-controlled re-trust of every transitive update into a code
   base auditable in an afternoon.
3. *Abstraction leaks hit safety code first.* Framework interrupt models
   resist exactly the HITL mutations (pause mid-batch, edit one
   argument, resume) that matter most; fighting them is where people
   fork frameworks or disable checks. Owning the loop owns the safety
   logic.

Hand-rolled here still means: battle-tested libraries for protocol
plumbing (HTTP, TLS, JSON) — the risk-minimizing middle is *own the
domain logic, delegate the protocols* (see :doc:`005-llm-client`).

Consequences
------------

- The agent loop, HITL interrupts/resume, memory/compaction, session
  persistence and tool subsystem are this project's own code, each
  covered by its own design docs and tests.
- Sagents/Jido remain documented non-choices: revisit only if the
  maintenance cost of the owned loop demonstrably exceeds the audit cost
  of re-trusting the framework tree.
- The stack is now: req_llm (ADR 005) → hand-rolled agent core →
  ex_termbox UI (ADR 004, ADR 006).