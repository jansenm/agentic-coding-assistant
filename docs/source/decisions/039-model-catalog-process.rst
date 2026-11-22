.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

The model catalog is one supervised process, loaded in the background
=====================================================================

.. adr::
   :id: 039
   :status: Accepted
   :date: 2026-09-30
   :tags: config, reliability, performance

.. note::
   Accepted 2026-09-30; implementation landed with this record. Fixes a
   startup regression introduced by ADR 037 (the mount blocked for
   seconds on llm_db's cold load) and makes the catalog a single,
   ownable component so it can be refreshed in place later. The refresh
   timer is deliberately **not** wired yet. (Amendment 2026-10-18 (2)
   wires it: a 24 h check against llm_db's own release store, re-cut for
   the installed pin into an artifact under the state directory.)

Context
-------

ADR 037 resolves a session's compaction window at init, in this order:
the layered ``context_window`` from ``config.toml``, then llm_db's
catalog window, then the 500k fallback. The catalog step runs
``LLMDB.model/1``, and llm_db loads its catalog **lazily on the first
query** — JSON-decoding the version-pinned ~8 MB snapshot while holding a
global load lock. Measured cold on the development machine:

  ``Store.load`` 7 ms · ``Session.resume`` **3726 ms**, of which the
  window resolution is 3816 ms (``Jason.decode!`` alone 476 ms; the rest
  is struct/pricing/filter over the whole catalog).

The mount therefore froze for ~3.7 s on **every fresh BEAM** (a ``mix
tui`` run), and the value it blocked on was not needed until the first
turn. Worse, for a cloud model absent from the catalog (the common
``ollama_cloud:*`` case) the lookup returns ``:not_found`` and the
fallback is used anyway — the work was pure waste. This was not a
pre-ADR-037 cost: before it, the sidebar read ``context_window_tokens``
from the app env (0 ms).

Two constraints shape the fix:

- **The catalog has exactly one consumer in OUR code.** ``Grep``/``Discovery``
  build the model menu, not llm_db; the only value we take from llm_db is
  the context window. (``req_llm`` itself reaches the catalog internally
  for native string specs — see Consequences — which is why a cold cache
  can still cost the first turn.)
- **llm_db is built to be a process-owned cache.** It stores the catalog
  in ``:persistent_term`` and swaps snapshots atomically by digest;
  reads are lock-free, and a load takes a global lock only while it
  runs.

Decision
--------

**1. The catalog is one supervised process**
(``CodingAgent.Core.Providers.Catalog``), started in the application
tree after the event registry. It warms llm_db in a ``handle_continue``,
so **app boot returns immediately** and the load happens in the
background. It is the single access point for our code: nobody calls
``LLMDB`` directly. (A future refresh — a timer calling ``LLMDB.load/1``
again and re-notifying — extends the same process; the timer is not
wired now.)

**2. Window resolution never blocks.** ``Catalog.context_window/1``
answers ``{:ok, tokens}``, ``:unknown``, or ``:loading`` (by checking
llm_db's ``:persistent_term`` snapshot — a lock-free read). A mount that
races the warm gets ``:loading`` and ``Config.context_window/2`` falls
back to the configured value or the 500k default, as before.

**3. A session re-resolves when the catalog becomes ready.**
``Session.init`` subscribes to ``{:catalog, :updated}`` when the window
is not pinned by ``config.toml`` (a configured value always wins, so
that case need not listen), and stores the provisional window. On the
signal it recomputes the window/limits and, if they or their SOURCE
changed, updates the state and publishes ``{:context_window, window,
soft, hard}``; the TUI mirrors the new numbers and the provenance in the
sidebar. The subscription is idempotent and delivers immediately when the
catalog is already loaded, so a subscriber never has to race the load.
(The source half is the 2026-10-18 amendment at the end of this ADR,
review N76: on an uncataloged model the numbers do not move.)

Consequences
------------

- **The startup hang is gone.** ``mix tui`` mounts in the ~50 ms the rest
  of the mount costs; the catalog finishes in the background, typically
  before the first turn needs it.
- **A very fast first prompt still pays the load.** The warm is
  asynchronous, so a prompt sent within the first ~4s of boot resolves
  the native string spec through ``req_llm``, which reaches ``LLMDB`` and
  takes the same ~3.7s cold load — in the provider path rather than the
  mount (measured: ``ReqLLM.model!/1`` cold ≈ 3.9s). Rare in practice (a
  human types slower than that), and bounded: the next call is warm. This
  is why "well before" is "usually before", not a guarantee.
- **The window is correct by the first turn.** The re-resolve lands
  within seconds of boot and before any user turn, so the compaction
  decision uses the real window. A ``config.toml`` ``context_window``
  still overrides everything and skips the subscription entirely.
- **Ownership is clear.** The catalog's lifecycle (load, and later
  refresh) lives in one module; consumers call an API that names what
  they want (a window), not the storage they use (llm_db). This is the
  seam a periodic refresh attaches to — config, not redesign.
- **Cost.** One more process in the tree and one more event in the
  vocabulary. Tests that assert a *cataloged* window must wait for
  readiness (the app warms it); tests that do not pin a window keep
  seeing the same 500k guess while the catalog is cold, so their numbers
  are unchanged.
- **The catalog only helps once a ``[providers.*]`` entry names a catalog
  provider.** The shipped ``config.toml`` declares only ``ollama`` and
  ``ollama_cloud``, neither of which is a req_llm catalog scope
  (``:ollama`` has zero candidates; ``:ollama_cloud`` does not exist
  there), so a stock install resolves the fallback window for everything
  (review N25). The menu's catalog half is likewise empty until a
  ``openai``/``anthropic``/… entry (or an explicit ``context_window``) is
  configured — expected, but worth stating so the "catalog half" work is
  not mistaken for a stock-install feature.
- **A resumed session is unaffected in the common case.** A model in the
  catalog re-resolves on the next boot; a model absent from it takes the
  ``:fallback`` guess either way.

**A session re-resolves when the PROVENANCE moves too (amendment
2026-10-18, review N76).** ``:loading`` and ``:fallback`` are two states,
not one: ``:loading`` is provisional and self-heals, ``:fallback`` is a
verdict about a model the loaded catalog does not know. Both answer the
same 500k guess, so a re-resolve that guards on the numbers alone
publishes nothing on the very flip it exists to announce — the sidebar
mirrored the source, kept ``:loading``, and never marked ``soft at`` as
``(assumed)``. The guard now compares the source as well, so
``{:context_window, …}`` means "what the session RESOLVED changed"; the
numbers in the payload may be the old ones, which is why the TUI re-reads
the source from the session instead of inferring it from the event.

**The sidebar dates the catalog it assumed from (amendment 2026-10-18,
review N106).** The snapshot is a *packaged* file, cut on llm_db's release
cadence — measured 2026-10-18: llm_db 2026.8.4 carrying a snapshot
generated 2026-08-23, against a 2026-10-14 release on Hex, i.e. 56 days
behind, with ``deepseek-v4.1-*`` absent although ``ollama_cloud`` is in
the catalog with 20 other models. A cloud model released since the cut is
therefore *missing*, which is the ordinary cause of a ``:fallback``
window, and a bare ``(assumed)`` gave no way to see why. The sidebar now
carries a ``catalog`` row (``2026-08-23 (56d)``, read from the snapshot's
own ``:meta.source_generated_at`` through ``Catalog.snapshot_age/0``)
whenever the catalog was actually consulted — muted when it answered,
warning-coloured when it did not know the model, hidden when the window is
``:configured`` or still ``:loading``.

Two corrections to this ADR's earlier text, same amendment: ``:ollama_cloud``
**does** exist as a catalog scope with 20 models (decision/Consequences,
``795a59d``, says it does not — the original N25 measurement was about a
specific model id, not the scope), and the "stock install resolves the
fallback window for everything" line holds only for models the snapshot
predates.

**Why not resolve the window from a live list instead?** The obvious
alternative — take the window from the same live fetch the model menu uses
(``Discovery``, ``GET <base>/models``) — was considered and rejected on
what that fetch returns: it is an id list (``map(& &1["id"])``,
``discovery.ex:261``), with no window in it. A provider's own ``/models``
would have to be trusted for a decision that governs compaction, and a
wrong number there is worse than a dated guess: it silently overruns the
model. So the catalog stays the only window source, the escape for a model
it does not know remains an explicit ``context_window``, and the age row
is what makes the gap visible. (``llm_db`` *can* load a non-packaged
snapshot — ``snapshot_source: {:github_releases, …}`` /
``{:file, path}`` — but that is a refresh source, still a snapshot from
someone else's cut, and it needs the network at boot; deferred with the
timer in Open question 1.)

**Why not the ``llmcatalog.dev`` REST API?** It serves the same llm_db
data fresh (``v2026.10.5``, i.e. the current line) and ``llm_db`` can
already read a remote snapshot (``snapshot_source: {:file, url}`` →
``Sources.Remote``), so it is tempting. Rejected for now: it adds an HTTP
dependency to the mount path — the window is resolved when a session
mounts, which is exactly the ``~3.7 s`` this ADR exists to get off that
path — for a value we already carry offline, and it would make a third
party a load-bearing input to how much context we dare send a provider.
It is a reasonable *refresh* source behind the same ``Catalog`` seam (Open
question 1), not a replacement for the packaged read.

Amendment 2026-10-18 (2): the catalog refreshes a copy it owns under ``$HOME``
-------------------------------------------------------------------------------

**Status: Accepted (amendment to the accepted ADR 039).**

Context
~~~~~~~

Open question 1 left the refresh unconfigured: no source, no timer. Two
measurements from the N106 work made that untenable. First, the packaged
snapshot is **56 days** behind the current llm_db line and misses models
that exist today (``deepseek-v4.1-*`` absent from a cut dated 2026-08-23),
so the window for a cloud model is a 500k guess — not because the data is
unavailable, but because the copy on disk is old. Second, the obvious
source is already reachable without any third party: llm_db ships its own
release store (``LLMDB.Snapshot.ReleaseStore``, default repo
``agentjido/llmdb``, keyless), which ``mix llm_db.snapshot.fetch`` already
uses. Measured 2026-10-18: the index holds **194** entries, latest
``generated_at 2026-10-16T04:13:01.974479Z``, ``provider_count 237``,
``model_count 9992``, and ``fetch_snapshot(:latest, …)`` wrote the document
locally (**11 330 065 B**).

Decision
~~~~~~~~

**1. The copy is the merged document, because the release document cannot
be loaded at all.** This is the constraint the whole design hangs on.
``snapshot_source: {:github_releases, …}`` — pointing llm_db at the feed
directly — is not a slower option, it is a **broken** one: the current
release doc passes ``Snapshot.read/2`` (``:ok``) and still fails the load
pipeline, on the pin installed here (``llm_db 2026.8.4``):

  ``LLMDB.Loader.load(snapshot_source: {:file, <release>})`` →
  ``{:invalid_snapshot_item, :provider, {:unknown_provider_id, "wallaby"}}``

**42 of the 237 provider ids are newer than the pin.** The reader's
vocabulary is *compile-time* generated — ``Generated.ProviderRegistry``
builds the provider atoms from the packaged file when llm_db is compiled,
and ``Generated.ValidModalities`` freezes the modality atoms the same way
— so ``Loader.provider_atom/1`` and ``deserialize_modality_list/1`` can only
accept what the pin already knew. Trimming to the registry-known providers
does not rescue it either: the surviving 195 providers / 8994 models
(10 177 235 B, 89.8 %) fail deeper, at
``{:invalid_snapshot_item, :model, {:unknown_modality, "decisions"}}`` —
27 entries in three providers (``azure``, ``openrouter``,
``cloudflare_workers_ai``; e.g. ``cloudflare_workers_ai/typesafe/jev`` whose
``modalities.output`` is ``["decisions"]``). Nothing about that is a bug in
the feed; the feed is simply cut by a newer line than the one reading it.

So the raw document is an **input**, never the artifact. The artifact is
the packaged document (197 providers, byte-identical to what the app loads
today) with the *configured* providers' entries replaced by the release's
cut, ``generated_at`` taken from the release, and the id recomputed:

  measured — ``8 356 127 B`` (packaged ``8 347 265 B``), 197 providers,
  ``Snapshot.read`` ``:ok``, loads 197 providers / 196 model groups in
  ~2.5 s cold, and answers
  ``ollama_cloud:deepseek-v4.1-flash → {:ok, 1048576}`` and
  ``ollama_cloud:glm-5.3-flash → {:ok, 1000000}`` where the packaged cut
  answers ``:unknown`` for both.

**2. Only configured providers are swapped, and only ones the installed
reader can digest.** Two failure modes are excluded by construction: a
provider id the compile-time registry does not know (one is enough to fail
the whole document) and a provider whose models carry a modality the pin
does not know. Both are cheap tests against the two generated modules, and
both must be applied *per provider*, because a single bad entry takes the
whole load down — there is no partial acceptance. Swapping the 192
registry-known, modality-clean providers instead of the configured one was
measured too: ``9 956 183 B``, 3.2 s, i.e. ~1.6 MB and ~0.7 s for
specifications the app has no ``[providers.*]`` entry for. The
conservative reading is also the smaller and faster one. A configured
provider that the release does not carry (``hostyourai`` is in neither
document; ``ollama`` is in neither) simply keeps its packaged entry and
its fallback window.

**3. The artifact lives in ``state_dir()``, and the app env is not
touched.** The file is ``Config.state_dir()/catalog.json`` — the
``$XDG_STATE_HOME/coding_agent`` directory that already holds ``store.db``
and ``tui.log`` — because it is state the application owns and rewrites,
not user configuration and not user data. The load passes
``snapshot_source: {:file, artifact}`` **explicitly**: the
``Application.put_env(:llm_db, :snapshot_source, …)`` seam does work (it
reaches even a bare ``LLMDB.load/0``; measured), but it is a process-wide
mutable that outlives the catalog, and a bare load elsewhere would silently
follow it — measured, a bare ``LLMDB.load()`` after an explicit artifact
load **reverted the store to the packaged cut** (``source_generated_at``
``2026-10-16 → 2026-08-23``), because the loader stores by digest and the
env still said ``:packaged``. The catalog stays the only caller of
``LLMDB.load/0`` (decision 1), and it names its source every time.

**4. A refresh verifies before it replaces, through the same call the app
uses.** ``snapshot_id`` is content-addressed over the canonical digest of
the document, so editing providers invalidates the base's
(``Snapshot.verify/1`` → ``:error``) and the id must be recomputed with
``LLMDB.Snapshot.snapshot_id/1`` — measured ``4ecaef4e…0763``,
``verify`` then ``:ok``. Because integrity is ``:strict`` by default, a
stale id is a document that never loads. The sequence is therefore: write
``catalog.json.<pid>.tmp``, load *that file* through
``LLMDB.Loader.load(snapshot_source: {:file, tmp})`` — parse, verify,
migrate, validate, deserialize, filter, i.e. everything the app does — and
only on ``{:ok, _}`` ``File.rename/2`` it into place. ``Snapshot.read/2``
alone is **not** sufficient evidence: the raw release doc shown above passes
it and fails the load. The rename is atomic, so a reader never sees a
half-written artifact, and the pid in the tmp name keeps two worktrees
sharing ``state_dir()`` from colliding.

**5. Cold start reads the artifact only if it loads; otherwise the
packaged file, with the reason logged.** A failed load leaves llm_db's
store ``nil``, and the next read then triggers llm_db's own **lazy** load
— measured: ``LLMDB.model/1`` on an empty store returns ``:ok`` after a
packaged load, and a ``{:file, missing}`` source yields ``{:error,
:enoent}`` with the store left ``nil``. That is correct behavior for
llm_db, but it is not the behavior this ADR wants on the boot path: the
catalog would stay ``:loading`` until some other process paid the blocking
load, exactly the hang ADR 039 removes. So the warm tries the artifact,
falls back to ``:packaged`` on any error, and logs which source won. The
catalog is never cold after boot.

**6. The refresh is checked once every 24 h, and on demand.** After the
warm lands, ``Catalog`` arms ``Process.send_after(self(), :refresh,
interval)`` — a few seconds for the FIRST check of a run (a copy may have
gone stale while the app was not running), the full interval after that —
and re-arms from one place after every attempt, so a failure never leaves
the catalog without a next check. On fire it refreshes when the artifact
is missing, older than the interval, or **unreadable**, and skips when it
is current. Off the boot path by construction: the check is a
``File.stat/1`` plus a read of the copy, and the fetch is a ~11 MB download
plus a merge plus a verify — seconds when it runs, and it never runs while
a mount is waiting. When the release's ``generated_at`` equals the
artifact's, the refresh is a **no-op** (same cut, nothing to re-cut): no
write, no notify, no subscriber churn. The ``/catalog`` verb forces past
the freshness check (a human who typed the command wants the copy updated,
not the policy re-explained) but not past the no-op.

The **unreadable** case is what makes the check self-healing. A copy that
will not load sends the warm to the packaged snapshot (decision 5), which
means every window afterwards quietly answers from the pin's cut and
nothing at runtime can tell — the failure is only visible as a warning in
the log. Treating a fresh-but-broken file as "nothing to do" would therefore
park the app on the packaged cut until the interval expired; ``due?/2``
reads the copy's own cut instead, so the next check rebuilds it.

A **failed** refresh is published as ``{:catalog, {:failed, reason}}``
rather than staying in the log: no window moved (the loaded copy is still
the one serving), so nothing needs re-resolving, but a human who asked for
the refresh — or whose sidebar date stopped moving — is owed the reason,
and ``Refresh.describe/1`` turns llm_db's nested error terms into one line.

**7. The raw download is an input cache, not the artifact.** It goes to
llm_db's own release-store cache (``<state_dir>/catalog-cache/snapshots/
<snapshot_id>.json``, retained two generations), which is content-addressed
and self-verifying: a torn or partial file fails the id check and is read
as a cache miss rather than as a corrupt catalog.

**8. What the refresh does not do.** It does not touch
``Discovery``'s per-process model-menu cache, does not re-enter
``Session``, and does not change the subscription contract: the new
snapshot is published through ``LLMDB.load/1``, subscribers receive the
existing ``{:catalog, :updated}``, and the session re-resolves its window
(decision 3 / N76). It also does not give a per-provider date: llm_db
carries one ``source_generated_at`` per snapshot, so the sidebar row dates
the **newest** data in the document (the release's cut), while the
providers left at the older cut keep no separate age. That is a
limitation of the reader, stated here rather than papered over. Nor does it
consult a project's ``[providers.*]`` table: the catalog is one process for
the whole app, started before any session, and it reads the process-wide
config layers — so a provider configured only in a repository's
``.coding-agent/config.toml`` is not refreshed. (It keeps its packaged
entry; nothing is lost, it is simply not re-cut.)

Acceptance
~~~~~~~~~~

``Catalog.Refresh`` with publicly parameterized ``build/3``, ``due?/2``,
``source/1`` and ``run/1`` (the ``Sandbox``/``Sandbox.Mounts`` precedent) so the
pipeline is driven by tiny documents in tests and the suite never touches the
network — the transport, the base document and the artifact path all read
through the same ``:catalog_refresh`` application-env seam. The merged artifact
is ``:ok`` under ``Snapshot.read/2``; configured providers are swapped while
unconfigured ones keep the packaged entry; a registry-unknown id and an unknown
modality are both refused per provider; a document that passes ``Snapshot.read/2``
and fails the LOAD is refused by the verify step and leaves the artifact
untouched; ``due?/2`` is false immediately after a refresh, true past the
interval, and true for a copy that will not read at all; the sidebar's
``catalog`` row moves to the release's date; and the running ``Catalog``
publishes ``{:catalog, :updated}`` after a refresh, ``{:catalog, {:failed,
reason}}`` after a failed one, and keeps its schedule either way. A FORCED
refresh that finds the copy current publishes ``{:catalog, :unchanged}``
(amendment 2026-10-25, review N121): "nothing to do" is an outcome, and the
``/catalog`` hint line that said "refreshing…" must hear it — before, that
case was silence and the note stayed on screen. A timer tick that finds
nothing due or nothing new publishes nothing; a daily "no news" note would
overwrite the hint line for a human who did not ask. The test run never arms
the timer (``interval_ms: :never``).

Open questions
--------------

1. **Refresh source and interval — RESOLVED (amendment 2026-10-18 (2),
   above).** The source is llm_db's own release store (``agentjido/llmdb``,
   keyless, the store ``mix llm_db.snapshot.fetch`` uses), consumed as an
   *input* into a locally re-cut artifact under ``state_dir()``; the
   interval is a 24 h check plus an on-demand verb. The alternative
   considered here — point ``snapshot_source`` at the feed — is not merely
   deferred but ruled out by measurement, and the ``llmcatalog.dev`` REST
   API remains unnecessary: it serves the same upstream data. (The obvious
   remaining alternative is to move the package pin: ``req_llm`` allows
   ``~> 2026.8.4``, so a transitive update cannot reach the current llm_db
   line; the packaged snapshot's date is shown in the sidebar — amendment
   above — so the stale pin is at least visible.)
   is to move the package pin: ``req_llm`` allows ``~> 2026.8.4``, so a
   transitive update cannot reach the current llm_db line; the packaged
   snapshot's date is shown in the sidebar — amendment below — so the
   stale pin is at least visible.)
2. **Per-model windows on model switch — RESOLVED (review N9, N26).**
   ADR 037 open question 1: the window resolved only for the model at
   init. ``Session.recompute_window/1`` now re-resolves on every
   effective-model change — ``apply_model/2`` (``set_model``),
   ``apply_pending_switches/2`` (the turn boundary) and the idle
   ``set_agent`` branch (N26: an agent definition may pin its own model,
   ADR 017). With the catalog loadable on demand the re-resolve is cheap.
3. **Provisional-window compaction.** If a turn is somehow sent before
   the catalog is ready on a cataloged model, the decision uses the
   provisional window — ``:loading``, the same 500k guess a loaded
   catalog that does not know the model answers as ``:fallback``
   (amendment 2026-10-18, review N76/N77). In practice the window arrives
   first; if that ever proves false, the pre-call pass already re-reads
   the state each turn, so the worst case is one decision on the guess,
   healed by the re-resolve.
