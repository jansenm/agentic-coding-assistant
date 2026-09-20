:orphan:

SQLite driver: exqlite, the one core-path NIF
=============================================

.. adr::
   :id: 023
   :status: Accepted
   :date: 2026-09-20
   :tags: dependencies, storage, sqlite, security, native

.. note::
   Accepted 2026-09-20. Invokes the pre-authorization in ADR 020's
   **S7** ("a native dependency is acceptable if it wins on
   requirements") and amends ADR 002's "no NIFs on the core path" to
   "one audited NIF, isolated at a module boundary". ADR 020 decides
   *that* the session engine is SQLite; this ADR decides *which driver*
   and records the exception it requires.

Context
-------

ADR 020 chose SQLite for the session store. SQLite has **no pure-BEAM
driver**: every mature option is a C NIF wrapping the SQLite
amalgamation. ADR 002 requires a pure Elixir/Erlang dependency tree, so
this is a genuine conflict, not an implementation detail. ADR 012
already set the precedent for a UI NIF (`ex_ratatui`, precompiled Rust)
on the grounds that it is "audited at the API boundary"; the session
store is *core*, so the same argument must be made explicitly.

Candidates:

``exqlite``
   MIT. The maintained SQLite3 library (successor to ``esqlite``). A C
   NIF built with ``elixir_make`` + ``cc_precompiler``; ships
   **precompiled** artifacts for common targets and compiles vendored
   SQLite from source otherwise. Raw ``Exqlite.Sqlite3`` API, no Ecto
   required.

``esqlite``
   C NIF, effectively unmaintained; the same class of dependency with
   less upkeep.

``ecto_sqlite3``
   Wraps ``exqlite`` with Ecto. Adds a query DSL and a large
   dependency (Ecto) that ADR 020 does not need — the schema is four
   tables and hand-written SQL is clearer than a schema DSL here.
   Rejected.

Measured on the target machine (2026-09-20, OTP 28 / Elixir 1.20):

- ``mix deps.get`` fetched ``exqlite`` 0.40.0 and it compiled after its
  build-order deps (``cc_precompiler``, ``db_connection``); the NIF came
  **precompiled** (``exqlite-nif-2.17-x86_64-linux-gnu-0.40.0.tar.gz``)
  — **no C toolchain was exercised** on this host. A C compiler is
  present (``gcc``/``make``) for platforms without a prebuilt artifact.
- The raw API round-trips correctly: ``open`` → ``execute`` (DDL) →
  ``prepare``/``bind``/``step``/``release`` (writes) →
  ``prepare``/``fetch_all``/``release`` (reads); ``BEGIN``/``COMMIT``/
  ``ROLLBACK`` via ``execute``; WAL mode is available
  (``PRAGMA journal_mode=wal``).

Decision
--------

Use **``exqlite`` (``~> 0.40``) directly**, via its ``Exqlite.Sqlite3``
module — one dependency, no Ecto.

The cost is accepted explicitly and bounded:

- **It is the one NIF on the core path.** ADR 002's "pure tree" is
  amended to "pure except this one audited NIF". Dependency count
  remains a security metric; this is a deliberate, recorded exception.
- **It is isolated at a module boundary.** All SQLite calls live behind
  ``CodingAgent.Core.Session.Store``; nothing else references
  ``Exqlite``. That is the "audited at the API boundary" property ADR
  012 claimed for the UI NIF — here the boundary is a single module with
  a small, testable API (``save``/``load``/``list``/``delete``/``rename``).
- **Build cost is small in practice.** Precompiled NIFs cover the common
  targets (no toolchain); source builds need a C compiler, which is the
  documented fallback, not the default here.

Consequences
------------

- ADR 002's Consequences section gains the NIF caveat (see amendment
  recorded there).
- The session store's *engine* is now SQLite, per ADR 020; the ADR 020
  slice order (verbs first, then engine) is unaffected — the verbs
  already shipped before this driver was added.
- ``Exqlite`` is a compile-time dependency of the app; a release built
  without a prebuilt artifact needs a C toolchain, which must be noted
  in the build docs.

Alternatives rejected
---------------------

- **No SQLite / keep blobs** — ADR 020 already decided the engine; the
  pure-tree constraint alone would block a decided feature on a
  self-imposed rule. S7 anticipated exactly this.
- **Ecto-based access** — a larger dependency and a DSL for four
  tables; ADR 020 chose SQL directly.
- **A pure-Erlang file format with no SQL** — would drop cross-session
  search/aggregation (``S1``/``S2``), the requirements that motivated
  SQLite.
