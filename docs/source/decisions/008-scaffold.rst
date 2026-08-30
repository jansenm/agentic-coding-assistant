:orphan:

Project scaffold: layout, configuration, toolchain pins
========================================================

.. adr::
   :id: 008
   :status: Accepted
   :date: 2026-08-29
   :tags: stack, layout, config

Context
-------

Implementation of the core loop (roadmap phase 1) begins. Decisions
needed before the first ``mix new``: repository layout, configuration
approach, version pins, and the project name (deferred, see below).

Verified facts: the development host provides Erlang/OTP 28
(ERTS 16.4.0.4) with Elixir 1.20.3. Upstream stable at decision time:
OTP 29.0.5 and Elixir 1.20.4. Dependencies pose no constraints
(req_llm requires Elixir ≥ 1.15, ex_termbox compiles via elixir_make).

Decision
--------

**Repository layout — one Mix application, strict internal boundaries.**
No umbrella (the owner's experience: umbrellas add friction without
benefit at this size). Module namespaces enforce the boundaries:

- ``AgentCore.*`` — loop, HITL, memory, tools, persistence;
  must never require a UI module.
- ``UI.*`` — terminal driver (ADR 004/006); must never call an LLM.
- A future split (TUI front-end vs. LLM back-end) remains possible
  because the boundary is a module-namespace rule from day one.

**Configuration — ``config.exs`` now.** All configuration collects
there while we learn which knobs actually exist. API keys are read via
``System.fetch_env!/1`` at usage sites (never committed). Splitting
config (per-agent files, runtime.exs, database) is a deliberate,
informed ADR once the inventory exists.

**Toolchain pins — OTP 28, Elixir ``~> 1.20``.** Pinned to the host
(host: OTP 28 / Elixir 1.20.3; current stable line: 1.20.4). OTP 29
exists but is deliberately not chased; Elixir 1.20's supported range is
the compatibility envelope. Reproducibility note: release artifacts
depend on the build host's OTP; a toolchain pin file (mise/asdf) and a
CI matrix are the follow-up, tracked in the roadmap.

**Project name — deferred (ADR 009).** The scaffold starts with a
placeholder module prefix; renaming before first release is cheap.

Consequences
------------

- ``mix new`` with a placeholder prefix; boundaries live in the module
  layout and code-review discipline, not in build tooling.
- config churn is accepted and cheap; the inventory drives the later
  design.
- The OTP/Elixir envelope is recorded here; CI should test the corners
  of the envelope, not just the host's current point release.