:orphan:

Session storage: selectable stores, per-store SQLite, two explicit views
========================================================================

.. adr::
   :id: 020
   :status: Proposed
   :date: 2026-09-19
   :tags: persistence, sessions, storage, memory, sqlite, tooling

.. note::
   Proposed 2026-09-19; being implemented. Supersedes the *format*
   commitment of slice 4a (``term_to_binary`` blob, ``Store``) without
   changing the domain contract: ``Store.save/1``/``load/1`` keep
   returning a ``%Core.Session.State{}``, so the storage change is
   encapsulated. The requirement that leads this ADR is **R0 — session
   management is a first-class product surface**, not the storage
   engine. The engine is chosen *after* the surface. Revisit the
   "Session storage principles" in ``explanation/memory.rst`` together
   with this ADR.

   Shipped so far: slice 1 (picker as session manager), slice 2 (store
   selection), and slice 3a (SQLite engine — one DB per store, metadata
   columns for listing, state BLOB for the lossless round-trip; driver
   chosen in ADR 023). Remaining: the normalized agent/display view
   tables.

Context
-------

Slice 4a chose the simplest thing that could work: one file per
session, one ``:erlang.term_to_binary({1, %State{}})`` blob, atomic
tmp+rename, fail-closed load (``explanation/memory.rst``). That choice
was correct for its moment, and its stated failure mode was opencode's
aggregated store.

Two things have since become true, and one of them reframes the whole
question.

**1. The persistence model contradicts the dual-view design.** Memory
is three tiers (``memory.rst``); the middle tier must carry **two
views**: the *agent view* (what the LLM sees, compacted) and the
*display view* (what the user sees, the immutable record compaction must
never touch). The store persists only the agent view
(``state.context``); the TUI reconstructs the display from it
(``Tui.restored_history/1``). That is wrong in two observable ways:

- **Reasoning is lost on resume.** ``:reasoning_delta`` is broadcast to
  the UI and discarded (``session.ex:1351``); nothing appends it to the
  context. Live you see the thinking; after ``--resume`` it is gone.
  The comment in ``Tui.persist_reasoning/1`` ("the full fidelity lives
  in the core session") is false.
- **Compaction erases visible history.** Compaction rewrites
  ``state.context`` to a summary plus the recent tail, so a resumed
  session shows a *lossy* transcript — exactly what dual-view forbids.

**2. The opencode objection is an API objection, not an engine
objection.** The experience that makes a database distasteful is: (a)
the session's directory is a secret password you must know to reach a
session, and (b) you must learn SQL to understand the blob. Neither has
anything to do with SQLite. It is a **product gap**: the store was built
without the verbs that make it legible. Every one of the operations a
user actually wants —

- list all sessions,
- list them with their storage footprint,
- delete one,
- delete all sessions belonging to a directory ``x/y/z``,
- search everything,

— was unavailable or required schema knowledge.

The lesson for this project: **the engine is an implementation detail
below the verbs. The verbs are the product.** A central, queryable
store is therefore not the enemy; it is the enabler — *provided* the
surface ships with it.

Measured on the dev machine (2026-09-19): 19 sessions / 582 KB total;
one live session 550 KB, of which ``state.context`` is 548 KB / 203
messages, dominated by tool output. ``Store.load`` ~1 ms, ``Store.list``
~13 ms — because ``list/0`` decodes every full state to read four
summary fields, so its cost scales with *total bytes*, not session
count.

Requirements
------------

Collected 2026-09-19, ordered by priority.

``R0`` — the leading requirement
   **Session management is a first-class product surface** (CLI *and*
   TUI): list, filter, search, show storage footprint, delete by
   id / age / size / **directory**, export, import — without SQL
   knowledge and without having to know the storage directory.

Hard
~~~~

``R1``
   Persist the **agent view** losslessly (exact ReqLLM round-trip).
``R2``
   Persist the **display view** separately and immutably; compaction
   never touches it. Include reasoning and tool metadata.
``R3``
   Persist gate state across an interruption (pending calls/results).
``R4``
   Never persist runtime-only fields (worker refs, queue, test seam).
``R5``
   Fail-closed load: corrupt / foreign / wrong version → error, never a
   half state.
``R6``
   Atomic durability: a crash must not destroy the last boundary.
``R7``
   A persistence failure must never kill a live session.
``R8``
   Schema evolution must not crash old or new readers.
``R9``
   Listing cost scales with the **number** of sessions, not their total
   bytes.
``R10``
   Lifecycle verbs are first-class: list, delete, prune by **age**, prune
   by **size**, delete by **directory**, export, import.
``R11``
   Path safety: a session id cannot traverse the filesystem.
``R12``
   Portability: a session is not bound to a directory; the scope root is
   *data inside* the session.
``R13``
   Size honesty: listing shows each session's footprint, and the store's
   total is a truthful answer to "how much session data do I have".
``R14``
   No daemon, no external service.
``R15``
   Deterministic, tested round-trip of the ReqLLM structs.
``R16``
   **Several selectable stores.** The user can keep more than one store
   — e.g. one per client/project — and point the tool at one of them.
   No automatic resolution *across* stores is required: the store is
   chosen explicitly.

Soft
~~~~

``S1``
   Cross-session full-text search **within the active store** ("in which
   sessions did I touch X").
``S2``
   Cross-session aggregation/reporting within a store (tokens per
   session, failures over time).
``S3``
   Export/import a single session as a portable artifact.
``S4``
   Human-readable / greppable / git-diffable session data.
``S5``
   ``--resume`` in two processes on one session is **not** required
   (single writer per session).
``S6``
   An automatic retention cap is wanted only if sessions can plausibly
   exhaust disk/quota; otherwise explicit pruning is enough.
``S7``
   A native dependency is acceptable **if** it wins on requirements.

Decision
--------

**R0 first: ship the verbs.** The storage decision below exists to
serve the surface, and the first slice is UI, not engine:

**Slice 1 (the actual first cut) — the picker becomes a session
manager.** Today the TUI picker lists id/status/age and deletes one
session. It gains:

- **storage footprint per session** (``R13``);
- a **search/filter field** over the active store (id, model, scope;
  content-level search rides the FTS table, ``S1``);
- **delete by directory**: group/filter by ``scope_root`` and delete a
  whole project's sessions after confirmation (``R10``).

This is largely achievable on today's blob (size via ``File.stat``,
filter in memory, directory from the loaded field) and delivers the
opencode complaint's fix before any format change. It also forces the
UI to stop assuming "sessions are everywhere and opaque".

**Then the engine: a *store* is one SQLite database that holds many
sessions**, with the agent view and the display view as separate tables
keyed by session id.

```
<store>.db          # one SQLite database; several sessions inside
```

.. note::
   **Reversal, recorded (2026-09-20).** The earlier draft of this ADR
   chose *a directory of per-session SQLite files*, preserving
   "one session = one portable unit = one ``rm``". The owner chose the
   opposite for now: **one DB per store, many sessions inside.** ADR
   020's own reasoning licenses the change — the opencode objection was
   an *API* objection (missing verbs), not an engine one — and an
   aggregated store makes cross-session search (``S1``), aggregation
   (``S2``) and the future ticket/coordination store native. The costs
   are stated plainly under *Consequences of aggregation* below; the
   property "one session = one file = one ``rm``" is **dropped** in
   favour of "one *store* = one file = one ``rm``", with single-session
   portability moved to ``--export``.

Schema (indicative, not final); every session-scoped table carries the
session id, which is the grouping key:

.. code-block:: sql

   -- per-session lifecycle/metadata (one row per session)
   sessions(id TEXT PRIMARY KEY, schema_version, model, status,
            scope_root, usage, policy, agent, mounts, turn_agents,
            saved_at, size_bytes)
   -- agent view: one row PER MESSAGE; `data` is that message's exact
   -- ReqLLM struct (term_to_binary BLOB). Compaction mutates THIS table.
   messages(session_id, seq, data BLOB,
            PRIMARY KEY(session_id, seq))
   -- display view: what the user sees; APPEND-ONLY, never compacted
   display(session_id, seq, kind, text, agent, meta,
           PRIMARY KEY(session_id, seq))
                                       -- kind: user|assistant|reasoning|
                                       -- tool|info
   -- gate state across an interruption
   pending(session_id, round_calls, round_results, tool_calls)
   -- search within the store
   display_fts (content='display')     -- FTS5 external content

Compaction ``DELETE``s and re-``INSERT``s in ``messages`` only (scoped to
one ``session_id``); ``display`` grows by append and is the immutable
record. Resume renders ``display`` directly; the agent view is only for
the next request. This is the dual-view pattern made structural.

Encoding decision (settled 2026-09-20)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

**The agent view's message content is stored as a ``term_to_binary``
BLOB; the display view is plain text.**

Options weighed: shred each message into typed columns (``role``,
``content``, ``tool_calls``, ``reasoning_details``, …), JSON text
(opencode's shape), or one BLOB per message.

- **Per-column shredding is rejected** because ``ReqLLM.Message`` carries
  multi-modal content parts, tool calls and provider-specific
  ``reasoning_details``/``provider_data``; flattening those into columns
  silently loses wire edges, violating ``R1``/``R15`` (lossless
  round-trip).
- **JSON is rejected** because it requires a hand-written
  ``ReqLLM``-to-JSON encoder that must stay exact against every wire edge,
  with an exactness test suite to prove it. It buys greppability **of the
  agent view** — a representation nobody greps.
- **Per-message BLOB is chosen.** The row is the appendable/addressable
  unit (append = one ``INSERT``, not a whole-context rewrite; compaction =
  ``DELETE`` a seq range), while the BLOB keeps the encoding exactly what
  the runtime already round-trips.

Greppability is served by the **display view**, which is *text by nature*
(it is what was rendered), so no encoder is needed to search a session:
``SELECT … WHERE text LIKE …`` runs in SQLite. ``display_fts`` is the
later upgrade if a store-wide scan proves slow. The trade-off accepted:
the agent view is not human-readable in the DB; ``--export`` covers the
"hand someone a readable session" case.

Schema versioning (gap found 2026-09-21)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The slice-3a schema ships with ``CREATE TABLE IF NOT EXISTS`` and no
version marker. That is **additive-safe** (a store written before the
``display`` table simply gains it on the next ``open/0``) but blind to
every change that is not a pure addition: a column rename, a type change,
an index that must be rebuilt. Such a change would run against an old
store with no way to know it is old, and fail at query time — violating
``R8`` ("schema evolution must not crash old or new readers").

There are **two independent version axes**, and conflating them is the
trap:

=================  =======================================  ==================
Axis               What it versions                           Where it lives
=================  =======================================  ==================
Agent-view format  the ``term_to_binary`` payload shape      ``format_version``
                   (``{version, %State{}}``)                  in each row's BLOB
Schema             the SQLite tables/columns/indexes        **missing**
=================  =======================================  ==================

``@format_version`` already guards the first (a mismatched BLOB fails
closed). Nothing guards the second.

**Decision: use SQLite's own ``PRAGMA user_version`` as the schema
version, plus an ordered migration list — a few lines, not Flyway.**

- ``user_version`` is a 32-bit integer stored in the DB header. Measured:
  it round-trips across close/reopen and costs one pragma read. No extra
  table, no extra file — the idiomatic SQLite slot for exactly this.
- On ``open/0``: read ``user_version``; if it is below the code's
  ``@schema_version``, run the pending migrations **in order**, inside a
  transaction, then set ``user_version`` to the target. If it is **above**
  the code's version, the store was written by a newer build → fail
  closed with a clear message (do not guess).
- Migrations are a list of `{version, fun(db)}`, appended, never edited:
  ``@migrations [{1, &create_v1_tables/1}, {2, &add_x/1}, ...]``. The
  first entry is the current schema as ``CREATE TABLE IF NOT EXISTS``, so
  a fresh store and an old store converge.
- Additive changes still work as they do today (``IF NOT EXISTS``), but
  they get a version number so the *next* non-additive change has a
  place to go.

This is deliberately not a migration framework: no checksums, no
rollback, no down-migrations, no CLI. The store is a user-local artifact
whose failure mode is "resume fails loudly", not "production outage" —
the honest scope is forward-only, in-process, tested migrations.

Consequences of aggregation (stated, not hidden)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- **Per-session portability is a verb, not a file copy.** Exporting one
  session becomes ``--session-export`` (a portable JSON document, or a
  small standalone DB), not "hand someone the file".
- **Size honesty is a query.** Each session's footprint is a stored
  ``size_bytes`` (updated on write) or ``SUM(length(...))`` over its
  rows, rather than a ``File.stat``; the store's own ``du`` is the whole
  DB including indexes.
- **Deletion is transactional.** ``DELETE FROM ... WHERE session_id = ?``
  across tables in one transaction, plus FTS maintenance — replacing the
  single ``rm``.
- **One writer.** SQLite's single-writer model is a good fit (``S5``:
  single writer per session already assumed); concurrent sessions in one
  store share the connection policy and must handle ``SQLITE_BUSY``.

**A store is a DB file, not a directory.** ``--store`` / ``AGENT_STORE``
/ ``config.toml store =`` resolve to a ``.db`` path. There is deliberately
**no UI to browse or rename stores**: the app knows only the *active*
store's path; other stores are just other files the user points at.

Store selection (R16)
---------------------

A store is a database **file** (``<name>.db``). Selection is explicit,
never guessed:

- **Default store**: ``~/.local/state/coding_agent/store.db``.
- **Named stores**: ``config.toml`` gains a ``[stores]`` table mapping a
  name to a ``.db`` path; ``store = "work"`` selects one.
- **Per-invocation**: ``--store <name|path>`` and the ``AGENT_STORE``
  environment variable override the default.

No verb resolves one session across multiple stores (the user's explicit
choice): you select a store, then list/search/prune within it. Switching
stores is a selection, not a query. **The app knows only the active
store's path** — there is deliberately no store browser, rename or
"where are my other stores" surface; another store is just another file
the user points at.

The *location* of a store is not special-cased. Pointing one at a path
inside a repository is possible because a store is just a file, but it is
not part of this design and has no dedicated verb: tool output can
contain secrets and runs to hundreds of KB, so committing a store would
leak and bloat. A repo store would only make sense as a deliberate,
gitignored choice, and that is exactly the kind of functionality this
project does not build before it is needed.

Why SQLite over the alternatives
--------------------------------

- **vs. binary blob + a ``display_history`` field** — fixes the reasoning
  symptom (``R2``) but leaves ``R9``, ``S1``, ``S2``, ``S3`` unanswered
  and keeps full-rewrite-per-boundary and shape-fragile healing.
- **vs. JSON envelope (one file)** — answers ``R9`` partly and ``S4``
  fully, but not ``S1``/``S2`` (no index; scan-and-decode), and a single
  JSON document re-serialises in full at every boundary.
- **vs. JSONL event log + snapshot** — best on ``S4`` and append-only
  display, zero new dependency; but cross-session search is
  ``rg``-outside-the-program and aggregation needs ad-hoc parsing, and
  the agent view still needs whole-document rewrites. Runner-up if
  ``S1``/``S2`` are dropped.
- **vs. ``:mnesia`` / ``:dets``** — pure BEAM, but neither is a portable
  single file with SQL/FTS; ``dets`` has a 2 GB limit and repair
  archaeology, ``mnesia`` is node-oriented. Rejected.
- **vs. one global database** — **chosen, with a correction.** The
  original draft rejected a single aggregated DB as opencode's failure
  mode. The rejection conflated *aggregation* with *the missing verbs*:
  per-session SQLite files answered the opencode complaint only because
  the listing/pruning surface was added alongside them, not because of
  the file split. The owner's decision (2026-09-20) is **one DB per
  store** — aggregation at the *store* level, several stores selectable
  — which keeps the unit you can ``rm`` and ``du`` (the store file)
  while making cross-session search/aggregation native. The rejected
  thing is the *single global* DB with no store boundary and no verbs,
  not aggregation itself.

Trade-off accepted: SQLite files are **not** ``cat``/``git``-readable
(``S4`` downgraded to a bonus). That is bought back by a JSON
``--export`` verb, which serves the sharing/readability case better than
the raw store would have.

Reconciliation with the existing principles
-------------------------------------------

The five "Session storage principles" (``memory.rst``) were written
against opencode's concrete failure modes, not against databases as
such. **One SQLite DB per selectable *store*** satisfies them, with one
principle deliberately reinterpreted:

1. **Portability over project-binding** — unchanged; ``scope_root`` is a
   column, and a store is a file you choose. A session is never bound to
   the directory it was opened in.
2. **One *store* = one file = one ``rm``** — **reinterpreted** (was "one
   *session* = one file"). The unit you can ``rm``/``du`` is now the
   store file; per-session deletability is a transactional ``DELETE``,
   and single-session portability moves to ``--export``. "Plaintext"
   stays dropped. See *Consequences of aggregation*.
3. **Lifecycle verbs first-class** — strengthened: this is now ``R0``,
   with delete-one / delete-by-directory / prune-by-age already in the
   picker, and prune-by-size/export/import following.
4. **Size honesty** — preserved via a per-session ``size_bytes`` (or
   ``SUM`` over rows); the store's own ``du`` covers indexes too. Growth
   is not hidden in an opaque global blob.
5. **Retention is a decision** — a default size guard is added (see
   *Retention*), documented here as this principle requires.

The ``memory.rst`` principles section should be amended to reference this
ADR (principle 2 wording; principle 4 gains the size guard; ``R0`` is
promoted to the lead commitment there).

Retention
---------

``S6``: no automatic deletion unless growth threatens disk/quota.
Decision:

- **Prune is explicit**: prune-by-age ships in the TUI picker (``P``);
  a size-based prune and delete-by-directory remain to add (the CLI
  ``--session-prune`` was retired with ``mix agent``, 2026-09-20).
- **One guard is automatic and loud**: a configurable per-session
  warning threshold (default generous, e.g. several MB) emits a warning
  when a session crosses it, so a runaway session is visible before it
  fills a disk. No silent deletion.

Migration
---------

Existing ``<id>.session`` binary files must keep working. The formats
are trivially distinguishable by magic bytes (``term_to_binary`` begins
``0x83``; SQLite begins ``SQLite format 3\0``):

- ``Store.load/1`` detects the format. A binary file is read with the
  existing path, handed to the state decoder, then **rewritten as SQLite
  once** (a lazy, in-place migration).
- A failed migration leaves the original file untouched and the session
  unreadable rather than half-converted (``R5``).
- A ``--session-migrate`` verb can convert a whole store explicitly;
  the lazy path keeps individual resumes working meanwhile.

Export/import
-------------

``S3``. Export writes a portable JSON document (``--session-export <id>``)
with the display view, meta and the agent view as plain arrays; import
validates the schema and writes a fresh session DB. **Redaction is part
of export**: ``meta.provider_config`` may carry user-written connection
info and must not ship secrets. This also retires the trust caveat: once
the store is SQL values, the ``binary_to_term`` atom-exhaustion vector
(``Store.safe_binary_to_term/1``) disappears.

Cross-session search and aggregation
------------------------------------

``S1``/``S2``, within the active store. Each database carries an FTS5
table over its display view. For a store-wide query the first
implementation scans the store's session DBs (open, query, close) — no
second artifact, cost scales with session count, acceptable for an
explicit verb. A derived store-level index (``index.sqlite``, rebuilt by
``--session-reindex``) is a **cache** that must never be the source of
truth; this ADR defers it. The picker's own listing needs only ``meta``
(``R9``), so it needs no index at all.

Implementation boundaries
-------------------------

- The format change is **inside ``Core.Session.Store``** plus a new
  encoder for the ReqLLM message list. ``State`` keeps its shape;
  ``Store.save/1``/``load/1`` keep their contracts, so ``Session``,
  ``State.restore/1`` (healing shrinks to a migration concern) and most
  of the UI are untouched.
- The session's ``persist/1`` call sites remain; only the write strategy
  changes from full-blob rewrite to table upserts.
- ``restored_history/1`` switches its source from ``state.context`` to
  the persisted display view.
- ``session.ex`` must append display events (user, assistant, reasoning,
  tool, info) at the boundaries it already persists.
- Store selection (``R16``) lands in ``Core.Config`` (one reader), the
  CLI tasks and the TUI picker.
- The TUI picker work (slice 1) is independent of the format change and
  can ship first.

Slice order
-----------

1. **TUI session manager** on the current store: footprint, search/filter,
   delete-by-directory (``R0``, ``R10``, ``R13``, ``S1`` within memory).
   **Shipped.**
2. **Store selection** (``R16``): config ``[stores]``, ``--store``,
   ``AGENT_STORE``; picker shows and switches the active store.
   **Shipped** (selection, not runtime switching — resolve at launch).
   ``Core.Config.resolve_store/2`` maps a selector (a ``[stores]`` name
   or an absolute/``~`` path) to a store DB path; ``select_store!/2``
   sets the ``:store_path`` seam; ``--store`` on ``mix tui`` (``mix agent``
   was retired 2026-09-20 — the TUI is the only surface),
   ``AGENT_STORE`` and ``config.toml store =`` are one reader with a
   strict precedence (explicit override > ``AGENT_STORE`` > config >
   default). An unresolvable selector raises rather than silently
   falling back to the default store. ``config.toml store =`` is the
   third fallback (the ``[stores]`` table only defines names).
3. **SQLite engine** (``R1``–``R9``). **Slice 3a shipped** (2026-09-20,
   ADR 023 chose the driver): the store is one SQLite DB file with a
   ``sessions`` table whose metadata columns (model, status, scope_root,
   saved_at, size_bytes) answer listings **without decoding a state**
   (``R9``); the full ``%State{}`` rides a BLOB column, so the round-trip
   stays lossless. **Slice 3b-i shipped** (2026-09-20): the **display
   view** is a separate, append-only, session-keyed ``display`` table of
   plain text, written by the session at the loop boundaries (user prompt,
   ordered reasoning/answer blocks, tool results, info notes). Resume
   renders it directly, so reasoning now survives and compaction cannot
   erase visible history. The session owns the ordered block list
   (``consume_stream`` returns it), since the display view is persisted
   core data. Remaining in slice 3: **normalize the agent view into
   per-message rows** (3b-ii) — a storage-efficiency change; the BLOB is
   still lossless today. Blob migration is intentionally ignored
   (unreleased).
   **Before** 3b-ii (which changes the schema non-additively), add the
   ``PRAGMA user_version`` migration list described under *Schema
   versioning* — otherwise there is no way to migrate an old store to the
   new shape (``R8``).
4. **Management verbs** (in the TUI, per the "TUI is the only surface"
   decision): delete-by-directory, prune-by-size, store-wide search,
   export/import. Delete-one, delete-visible, and prune-by-age already
   ship in the picker (``d``/``D``/``P``).
5. **Derived store index** only if store-wide search proves slow.

Open questions
--------------

1. Store selection in the TUI: switch at runtime, or only at launch?
   **Resolved in slice 2: at launch.** The selector resolves once
   (``select_store!/2`` sets the seam before the TUI mounts); the picker
   *names* the active store but does not switch it. Runtime switching
   would have to re-point ``Store.path/0`` under live sessions and is
   deliberately out of scope (S5: single writer per session).
2. Exact retention defaults: warning threshold value; whether a
   size-prune verb is in the first slice.
3. Does the display view need tool *arguments* (not only results) for a
   faithful resume? Today the UI shows results; the request that
   produced them lives in the agent view.
4. ``--export`` format: the JSON document above, or a self-contained
   ``.session`` (SQLite) file that is simply copied?
