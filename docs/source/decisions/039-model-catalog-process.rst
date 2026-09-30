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
signal it recomputes the window/limits and, if they changed, updates the
state and publishes ``{:context_window, window, soft, hard}``; the TUI
mirrors the new numbers in the sidebar. The subscription is idempotent
and delivers immediately when the catalog is already loaded, so a
subscriber never has to race the load.

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
  seeing the fallback while the catalog is cold, so their numbers are
  unchanged.
- **A resumed session is unaffected in the common case.** A model in the
  catalog re-resolves on the next boot; a model absent from it already
  used the fallback.

Open questions
--------------

1. **Refresh source and interval.** The process is the place for a timer
   (``Process.send_after`` → ``LLMDB.load/1`` → notify), but no source is
   configured. llm_db defaults to the version-pinned packaged snapshot
   (no network); a live feed would set
   ``snapshot_source: {:github_releases, …}``. Deferred until a feed is
   wanted; the timer is intentionally absent now.
2. **Per-model windows on model switch.** ADR 037 open question 1 still
   stands: the window resolves for the model at init; a later switch
   does not re-resolve. With the catalog now loadable on demand, the
   switch path *could* re-resolve cheaply — but that is a decision for
   that question, not this record.
3. **Provisional-window compaction.** If a turn is somehow sent before
   the catalog is ready on a cataloged model, the decision uses the
   fallback window. In practice the window arrives first; if that ever
   proves false, the pre-call pass already re-reads the state each turn,
   so the worst case is one decision on the fallback, healed by the
   re-resolve.
