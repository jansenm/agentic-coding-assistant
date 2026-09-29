:orphan:

Provider timeouts are retried, and an empty answer is a failure
===============================================================

.. adr::
   :id: 033
   :status: Accepted
   :date: 2026-09-29
   :tags: providers, sessions, config, ui

.. note::
   Accepted and implemented 2026-09-29. A transient provider timeout used
   to end the turn, and a stream that finished cleanly with no content
   used to settle the session to ``:idle`` as if the turn had succeeded —
   the "idle mid-task with no clean finish" report. Timeouts are now
   retried (default 3 times, 5 s apart, both configurable) and an empty
   answer fails the turn loudly.

Context
-------

Dogfooding a long session produced three symptoms in one day: a native
NIF crash (separate, ADR-less, recorded in ``tui.log``), a provider
timeout, and then a session that went ``:idle`` in the middle of a task
with no error and no final answer. The timeout and the silent idle are
the same failure seen twice.

The turn loop consumes req_llm's projected events
(``ReqLLM.StreamResponse.events/1``). That projector emits a terminal
``:finish`` (carrying a ``finish_reason``) or ``:cancelled``/``:error``
event after the last delta
(``deps/req_llm/.../event_projector.ex``, ``terminal_event/2``). Our
``handle_event/4`` matched only ``:text_delta``, ``:reasoning_delta``,
``:tool_call`` and ``:error``; everything else — including the terminal
``:finish`` — fell through to the catch-all.

Two consequences follow, both observed:

1. **A transport timeout is terminal.** req_llm surfaces a structured
   ``%ReqLLM.Error.API.Timeout{}`` (``kind: :connect | :receive | :total |
   :stream_idle``). The loop turned it into ``fail_turn/2`` immediately.
   A network hiccup on one request ended a turn that a second attempt
   would have completed.
2. **A clean empty finish looks like success.** When the provider ended
   the stream with ``:finish`` and nothing before it, the accumulator was
   empty: ``classify([]) -> :final_answer``, ``text = ""``. The loop then
   ran ``complete_turn(state, "", blocks)`` — appending an empty assistant
   message, broadcasting ``{:status_changed, :idle}``, and persisting.
   The human sees the session go idle mid-task, with no error line and no
   answer. The empty assistant message is also an invalid wire payload for
   strict OpenAI-compatible backends (``content_invalid?/1``).

A second, independent defect was found in the same log: ``Session.state/1``
used ``GenServer.call/2``'s 5 s default timeout, and an uncaught ``:exit``
from a momentarily busy session **terminated the TUI server**
(``ExRatatui.Server terminating ... GenServer.call(... :state, 5000) EXIT
time out``). A state *read* must never kill its caller.

Decision
--------

**1. A provider timeout is retried, bounded and configurable.** The turn
worker retries a failed provider call up to ``provider_retries`` times
(default **3**), waiting ``provider_retry_delay_ms`` (default **5000**)
between attempts. Both resolve through the one configuration boundary
(ADR 008), layered ``config.toml`` (project over global) over the
app-env seam over the built-in default, exactly like ``max_tool_rounds``
(ADR 025). ``provider_retries = 0`` disables the retry.

**2. Only a timeout is retried, and only with nothing streamed.** The
retryable class is the one classifier in ``Core.Failure``
(``retryable_timeout?/1``): the structured ``%ReqLLM.Error.API.Timeout{}``,
a timeout-wrapped ``{:http_task_failed, :timeout}``, or a transport reason
that names a timeout in words (some providers surface a textual "timed
out" instead of the struct). Auth, 4xx/5xx and local build failures are
permanent for the turn, as before. A timeout *after* partial output is
also not retried: re-asking the model would duplicate text the human
already saw. The worker tracks whether the last attempt emitted a
visible delta to make that call.

**3. An empty "successful" finish is a failure, not an idle turn.** A
``{:ok, %{text: "", tool_calls: [], blocks: []}}`` result is retried like
a timeout; once retries are exhausted it becomes
``{:error, {:empty_provider_response, n}}``, which flows through the
existing ``fail_turn/2`` path — a named error line in the transcript, not
a silent empty answer. ``Failure.classify/1`` places it with the provider
and invites a retry.

**4. The retry decision is pure and testable.** ``Session.llm_retry/4``
returns ``:retry_timeout | :retry_empty | :give_up | {:give_up, reason}``
from the attempt result, whether output streamed, and the attempts left —
no provider, no side effects. ``call_llm/2`` wraps the real stream in
``retry_llm/5``; the wait honors a user stop (esc) in 100 ms slices, so a
back-off never blocks a cancel.

**5. ``Session.state/1`` never kills its caller.** The read catches the
``:exit`` from ``GenServer.call/2`` (a gone session, or the 5 s timeout)
and returns ``{:error, :not_found}`` / ``{:error, :timeout}``. Callers
already branch on ``{:error, _}``; the TUI's many render/key reads can no
longer take the whole UI down.

Consequences
------------

- A transient provider timeout costs a few seconds, not a turn.
- The "idle mid-task, no clean finish" symptom is gone: an empty stream
  is either retried or reported as a failed turn.
- The retry is conservative by construction: no duplication after
  partial output, no retry of permanent failures.
- Two new knobs (``provider_retries``, ``provider_retry_delay_ms``) join
  the documented runtime surface; their defaults live once in
  ``Core.Config``.
- The retry loop adds an inner recursion over ``call_llm``; the terminal
  ``:finish`` event is still not inspected for its ``finish_reason``
  (see open questions), because the empty-result check covers the
  observed failure without coupling the loop to a provider field.

Open questions
--------------

1. **Should a non-``stop`` finish reason (``length``, ``content_filter``)
   be named?** Today only an empty result is special-cased. A truncated
   answer that *did* emit text stops the turn as a normal answer; naming
   ``finish_reason: length`` would let the human know the answer was cut.
2. **Should the retry delay back off (exponential) instead of fixed?**
   A fixed delay matches the request ("5 s apart, configurable"); a
   provider under sustained load might prefer 5/10/20. Deferred until
   there is evidence.
3. **Should ``provider_retries`` be per-provider?** It is per-session
   today (a global/project knob). A flaky local ollama and a cloud
   endpoint may want different policies; the provider table
   (ADR 014) is the natural home.
