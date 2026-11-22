.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

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
4. **``req_llm``'s own ``max_retries: 3`` DO retry an idle transport
   timeout — on the Finch path, corrected by review N29.** The original
   claim here read the post-start stream classification
   (``ReqLLM.Streaming.Failure.classify/1`` rates a bare ``:timeout``
   ``:unknown`` → ``:no_retry``). But a timeout BEFORE any response body
   goes through ``ReqLLM.Streaming.Retry.stream/6``'s Finch loop, which
   classifies it ``{:transport, :timeout, true}`` → ``{:retry, 0}`` and
   reconnects (measured: ``max_retries: 0/1/3`` → 1/2/4 connections on a
   silent stub). The **session's** retry layer *does* retry it too
   (``Failure.retryable_timeout?/1``), and with ``provider_retries: 3``
   and ``provider_retry_delay_ms: 5000`` that is ``(3 + 1) × timeout +
   3 × 5s`` of near-silent waiting before the turn ends (the review
   ``review.md`` §6 concern). The two layers compound: the abandoned
   stream's own retries ran on after the error surfaced (see the
   Consequences note and ``session/stream_close_test.exs``).

Decision
--------

**1. A layered ``provider_receive_timeout_ms`` knob.** Resolution mirrors
``provider_retries/1``: the layered ``config.toml`` key (project over
global), the app-env override, then the default. The default is
``120_000`` — the value ``req_llm`` itself uses for images, chosen over
the raw 30s so a thinking model has room, but well under the 300s the
Responses/thinking path allows.

**2. One place sets it: ``Request.build/3``.** Both the turn and the
compactor build through ``Request.build/3``; putting ``receive_timeout``
there means they share one source and cannot drift (the same reason
credentials and base URLs already live there). ``build/3`` reads
``Config.provider_receive_timeout_ms(scope_root)`` so a PROJECT
``config.toml`` applies like every other layered knob (review N23: the
first version called the no-scope form, silently ignoring the project
layer the docs promised). The scope root is threaded from the session's
state; ``build/2`` is the global/app-env form for tests.

**3. The knob is per-request, and does not disable the retry chain.**
Raising the timeout raises the worst-case turn time proportionally
(``retries + 1`` attempts × timeout). That is the deliberate trade: wait
longer for a slow model rather than fail a good turn. A deployment that
wants a tighter bound lowers ``provider_retries`` rather than the timeout.

Consequences
------------

- A reasoning model with a slow first token no longer fails at 30s; it
  gets 120s of silence before the harness gives up.
- The compactor already used an explicit inactivity budget
  (``compaction_inactivity_ms``); this does not change it (the compactor
  passes its own ``receive_timeout``, which wins).
- The worst-case turn time is now ``(provider_retries + 1) × timeout +
  provider_retries × delay`` ≈ **495s** (8.3 min) by default, up from
  ~105s. (``provider_retries`` is the number of RETRIES, so there are
  ``retries + 1`` attempts and ``retries`` delays; the earlier 375s here
  forgot the first attempt — review N28.) That is visible and
  configurable; the status line still names the retry.
- ``req_llm``'s own ``max_retries`` DOES affect an idle transport timeout,
  contrary to finding 4 as originally written (corrected by review N29):
  the pre-body timeout is classified ``:retry`` by
  ``ReqLLM.Streaming.Retry``'s Finch loop (not by the post-start
  ``:unknown → :no_retry`` stream classification). An abandoned stream
  therefore kept retrying behind the surfaced error, compounding with the
  session's own retries (measured 11 provider connections for one failed
  turn). ``stream_attempt/2`` now closes the response on the error path,
  which ends that loop (measured 4). See ADR 043-adjacent work; the fix
  and its regression test live in ``session/stream_close_test.exs``.

Open questions
--------------

1. **The double-retry on transport errors.** ``econnrefused`` is retried
   by ``req_llm`` (3×, its ``Retry.stream``) *and* by the session (3×).
   One half is now closed: the abandoned stream is closed on the error
   path (N29), so its own retries stop instead of running on behind the
   session's. Fully disabling one layer is still a separate decision;
   this ADR fixes the value and the close.
2. **Streaming semantic-progress timeout.** ``req_llm`` exposes
   ``stream_idle_timeout`` (fail on no *semantic* progress) distinct from
   the socket ``receive_timeout``. We set neither; if slow-but-alive
   streams become a problem, that is the next knob, not a longer socket
   timeout.
3. **Per-provider timeouts.** The knob is global. A slow local model and
   a fast cloud model may want different budgets; a ``[providers.*]``
   key is the natural extension if that proves needed.
