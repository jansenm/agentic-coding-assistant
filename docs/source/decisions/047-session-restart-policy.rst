:orphan:

A session is never restarted; a crash is the outcome
====================================================

.. adr::
   :id: 047
   :status: Accepted
   :date: 2026-10-24
   :tags: sessions, supervision, otp, persistence

Context
-------

``Session.Supervisor.start_session/1`` had started every session with
``restart: :transient`` since the first session commit (``6cb4e99``,
2026-08-30). The intent was the obvious one — an agent session should not
disappear because of a crash — and the ``:normal`` half of ``:transient``
is still the right behaviour: the subagent seam retires a finished child
with ``Session.stop/1``, and it must not come back.

The ``:abnormal`` half does not do what it looks like. OTP restarts a
child **from its child spec**, and this spec carries the start options
captured when the session was first mounted::

    %{id: id, start: {Session, :start_link, [opts]}, restart: :transient}

So the restart is not a recovery, it is a **new session with the same
id**: ``Context.new()`` plus the system prompt, the configured model, the
start-time agent, zero usage. The conversation is gone from the live
process. Measured (``MIX_ENV=test mix run --no-start``, one seeded
conversation of seven messages and a model switch, both policies on the
same seed)::

    :transient   after kill: LIVE model=start-model messages=1
                 after one boundary: store has messages=1     <- clobbered
    :temporary   after kill: {:error, :not_found}
                 store has messages=7, model=switched-model   <- intact

Two lines to read carefully. **After the kill the live process already
held the wrong thing** — the transcript on screen and the state behind it
disagreed, with nothing saying so. And **the next turn boundary wrote
that wrong state over the persisted one**: the store row dropped from
seven messages to one. A crash with ``:transient`` was not "the session
comes back a little stale", it was **silent data loss on the first turn
after the crash**.

Decision
--------

**1. Sessions are `restart: :temporary`.** A session's death is an
outcome, not an interruption to paper over. The registry entry goes away,
every ``Session`` call already degrades to ``{:error, :not_found}``
(``safe_call/4``), and the store keeps exactly what the last turn
boundary wrote.

**2. Recovery is a verb, not a supervision side effect.** The driver that
wants the conversation back calls ``Session.resume/2`` — the path the
picker already takes (``resume_opts/2`` restores the base policy, the
resumable agent, usage, warned/backoff and a parked round). A supervision
restart cannot do this, because a restart has no caller and therefore
nobody to tell what was lost. Rolling a session back to its last boundary
in the background, while the driver still paints the pre-crash
transcript, is the same lie in a nicer form.

**3. The driver says what happened.** The TUI reports a dead session as
what it is (``error_text/1`` for ``:not_found``): *the session process is
gone (it stopped or crashed) — the saved conversation is intact;
/sessions reopens it*. Before, ``:not_found`` fell through to the generic
"check the provider" text, which sent the reader after the wrong cause —
the same mistake the classified-failure path already fixed for provider
errors.

**4. One crash may not take the other sessions.** A ``DynamicSupervisor``
applies OTP's default intensity (``max_restarts: 3``,
``max_seconds: 5``) to its children **as a group**. Under ``:transient``
four crashes of one session inside five seconds therefore killed the
whole session supervisor, and every other live session with it. Measured
against the application's own supervisor: the fourth kill produced
``{:DOWN, …, :shutdown}``, an unrelated session died, and the parent
rebuilt an empty supervisor. A policy that never restarts a child cannot
exhaust that budget, so this hazard is removed by decision 1 rather than
by tuning ``max_restarts``.

Rejected alternatives
---------------------

- **A start spec that reloads the store before restarting.** It keeps the
  bytes, and is still the wrong shape: the restarted process would resume
  from the last boundary while the driver's screen still shows the
  in-flight turn — no event tells anyone that the turn was lost, the
  round counter and the parked gate state are whatever the file said, and
  "resume" would silently become a behaviour nobody asked for. It also
  makes the session's identity depend on a *file read succeeding inside a
  supervisor restart*, whose failure mode (crash loop, then the group
  budget) is exactly the one decision 4 removes.
- **``restart: :transient`` with a bigger ``max_restarts``.** Treats the
  symptom of decision 4 and leaves the data loss of decision 1 untouched.
- **Keeping the session alive instead of letting it crash.** Not
  available: the crash is the signal. ``fail_turn/2`` already turns turn
  failures into an ``:error`` status with a transcript line, so a session
  process that dies has hit something the loop could not contain.

Consequences
------------

- A crashed session is visibly gone; the next prompt in that view fails
  with a sentence that names the state and the verb (``/sessions``).
- The store can no longer be overwritten by a process that never held the
  conversation — the first-writer-after-crash hole is closed for the
  supervision path.
- ``Session.stop/1`` no longer relies on ``:transient`` for the subagent
  seam; ``:temporary`` covers the orderly stop too, so the comment that
  explained the seam ("a normal stop is not restarted") is now a statement
  about the policy, not about this one caller.
- Review N98 remains open and is now smaller: orphaned turn workers can
  still broadcast and write under a dead session's id. With no impostor
  they are the *only* writer, so the "two writers on one id" sentence no
  longer applies — the orphan is still a bug, not a data race.

Open questions
--------------

1. **Should the TUI monitor the session?** Today a dead session is
   reported on the next prompt, not at the moment of death. A monitor
   would paint the failure immediately, at the cost of a second liveness
   source next to the event channel. Not built: the failure is already
   legible, and a spurious "gone" line while the session is restarting
   would be worse than a late true one.
2. **Does a resume need to say where it started?** ``resume_opts/2``
   restores the last boundary; a turn that was in flight when the process
   died is not in that boundary. If that turns out to surprise people,
   the resume notice can name the boundary's timestamp.
