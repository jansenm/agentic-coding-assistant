.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

Elixir and OTP as the runtime
=============================

.. adr::
   :id: 002
   :status: Accepted
   :date: 2026-08-29
   :tags: stack

Context
-------

Existing coding assistants are overwhelmingly Node/JavaScript based, often
requiring bootstrap toolchains (e.g. Bun) or prebuilt binaries. Given
current supply-chain attacks against open source, a coding assistant that
handles source code and credentials must be **trustworthy, lightweight and
trivially compilable from source** by anyone.

Decision
--------

The assistant is implemented in **Elixir on the BEAM**:

- the whole dependency tree is pure Elixir/Erlang (no NIFs on the core
  path, no Node),
- ``mix release`` builds from source with only Erlang/Elixir installed,
- ``mix.lock`` checksums every transitive dependency, keeping the auditable
  surface small.

Consequences
------------

- Dependency count is treated as a security metric; every dependency
  addition worth discussing gets an ADR.
- UI choices are constrained to BEAM-native options (terminal, LiveView).
- **NIF exception (amended 2026-09-20).** "No NIFs on the core path" is
  relaxed to "no NIFs except those explicitly recorded and isolated at a
  module boundary". Two exist: `ex_ratatui` (UI, precompiled Rust; ADR
  012) and `exqlite` (session storage, precompiled C; ADR 023). The
  "pure Elixir/Erlang tree" claim holds for everything else; each
  exception is argued in its own ADR and confined behind one module.