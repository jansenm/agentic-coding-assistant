:orphan:

The turn's transport timeout is explicit (measured, not the 30s default)
========================================================================

.. adr::
   :id: 041
   :status: Accepted
   :date: 2026-09-30
   :tags: providers, reliability, config

.. note::
   Accepted 2026-09-30; implementation landed with this record. Adds one
   layered knob (``provider_receive_timeout_ms``) and wires it onto the
   turn's request options, so the streaming call uses a deliberate
   inactivity budget instead of inheriting ``req_llm``'s 30s default.
   Written after the observed pattern of frequent provider timeouts; the
   numbers below are local measurements through the real request path.

Context
-------

The turn's provider call (``Session.stream_attempt/2`` →
``Request.build/2`` → ``ReqLLM.stream_text/3``) set **no** timeout. So
the transport used ``req_llm``'s default: ``receive_timeout: 30_000``
(``ReqLLM.Provider.Defaults.prepare_chat_request/4``, and
``ReqLLM.Providers.OpenAI.get_timeout_for_operation/2``). The compaction
summarize call, by contrast, already passed an explicit
``receive_timeout`` (``compaction_inactivity_ms``, default 120s); only
the turn inherited the default.

``receive_timeout`` on a streaming call is the **inter-chunk idle
timeout**: the socket may be silent for at most that long before the
call fails. It is not merely a connect timeout. A reasoning model that
thinks before its first token, or a congested cloud endpoint, can exceed
30s of silence easily — and the failure then costs the full retry chain
(see below), not a fast fail.

Measurement
-----------

A local OpenAI-compatible SSE server (controlled delay before the first
byte and between chunks) was called through the **real** path —
``Request.build/2`` then ``ReqLLM.stream_text/3`` — so the numbers are
the harness's own, not ``req_llm``'s in isolation.

.. list-table::
   :header-rows: 1
   :widths: 8 46 46

   * - Case
     - Configuration
     - Result
   * - A
     - fast server, defaults
     - ``{:ok, "hello world"}``
   * - B
     - 5s stall before first byte, defaults
     - ok (9.4s wall)
   * - C
     - 5s stall, ``receive_timeout: 3000``
     - **timeout** (6.7s)
   * - D
     - **35s stall, defaults**
     - **timeout at 34.3s** — the 30s default fires
   * - E
     - 35s stall, ``receive_timeout: 60000``
     - ok (39.2s)
   * - F
     - 5s gap *between* chunks, ``receive_timeout: 3000``
     - **timeout** (6.5s) — idle, not just connect

Four findings:

1. **The 30s default fires on the turn path.** Case D shows a single
   ~30s timeout; the turn sets no override, so a model silent >30s fails.
2. **It is an idle timeout, not only connect.** Case F fails mid-stream
   when chunks pause longer than the budget.
3. **An explicit ``receive_timeout`` overrides cleanly** (C, E): the
   knob exists and works.
4. **``req_llm``'s own ``max_retries: 3`` do NOT retry an idle timeout.**
   A 35s stall produced exactly one 30s timeout with no retry log. The
   idle timeout arrives as a bare ``:timeout``, which
   ``ReqLLM.Streaming.Failure.classify/1`` rates ``:unknown`` →
   ``:no_retry``. But the **session's** retry layer *does* retry it:
   ``Failure.retryable_timeout?/1`` classifies the stream error
   (``{:stream_error, %ReqLLM.Error.API.Stream{reason: "Stream failed:
   :timeout"}}``) as retryable. With ``provider_retries: 3`` and
   ``provider_retry_delay_ms: 5000`` that is **3 × (timeout + 5s)** of
   near-silent waiting before the turn ends — the failure the review
   flagged (``review.md`` §6).

Decision
--------

**1. A layered ``provider_receive_timeout_ms`` knob.** Resolution mirrors
``provider_retries/1``: the layered ``config.toml`` key (project over
global), the app-env override, then the default. The default is
``120_000`` — the value ``req_llm`` itself uses for images, chosen over
the raw 30s so a thinking model has room, but well under the 300s the
Responses/thinking path allows.

**2. One place sets it: ``Request.build/2``.** Both the turn and the
compactor build through ``Request.build/2``; putting ``receive_timeout``
there means they share one source and cannot drift (the same reason
credentials and base URLs already live there). ``Request.build/2`` reads
``Config.provider_receive_timeout_ms/0`` (an app-env/layered read, no
snapshot needed — the turn already carries the provider snapshot in its
opts, and this is a runtime knob like the compaction budgets).

**3. The knob is per-request, and does not disable the retry chain.**
Raising the timeout raises the worst-case turn time proportionally (3
retries × timeout). That is the deliberate trade: wait longer for a slow
model rather than fail a good turn. A deployment that wants a tighter
bound lowers ``provider_retries`` rather than the timeout.

Consequences
------------

- A reasoning model with a slow first token no longer fails at 30s; it
  gets 120s of silence before the harness gives up.
- The compactor already used an explicit inactivity budget
  (``compaction_inactivity_ms``); this does not change it (the compactor
  passes its own ``receive_timeout``, which wins).
- The worst-case turn time is now ``provider_retries × (timeout +
  delay)`` ≈ 375s by default, up from ~105s. That is visible and
  configurable; the status line still names the retry.
- ``req_llm``'s ``max_retries`` stays at 3 but is inert for idle
  timeouts (finding 4); it only matters for transport errors like
  ``econnrefused``, where it *and* the session retry — a known, separate
  double-retry.

Open questions
--------------

1. **The double-retry on transport errors.** ``econnrefused`` is retried
   by ``req_llm`` (3×, its ``Retry.stream``) *and* by the session (3×).
   Measuring and, if needed, disabling one layer is a separate small
   session; this ADR only fixes the timeout value.
2. **Streaming semantic-progress timeout.** ``req_llm`` exposes
   ``stream_idle_timeout`` (fail on no *semantic* progress) distinct from
   the socket ``receive_timeout``. We set neither; if slow-but-alive
   streams become a problem, that is the next knob, not a longer socket
   timeout.
3. **Per-provider timeouts.** The knob is global. A slow local model and
   a fast cloud model may want different budgets; a ``[providers.*]``
   key is the natural extension if that proves needed.
