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
   timer is deliberately **not** wired yet.

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

Open questions
--------------

1. **Refresh source and interval.** The process is the place for a timer
   (``Process.send_after`` → ``LLMDB.load/1`` → notify), but no source is
   configured. llm_db defaults to the version-pinned packaged snapshot
   (no network); a live feed would set
   ``snapshot_source: {:github_releases, …}`` — and llm_db's release
   store defaults to the ``agentjido/llmdb`` GitHub repo, an asset host,
   **not** the operator's own service. Deferred until a feed is wanted;
   the timer is intentionally absent now. (The obvious alternative today
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
