.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

esc kills a running tool command (mid-tool hard cancel)
=======================================================

.. adr::
   :id: 043
   :status: Accepted
   :date: 2026-09-30
   :tags: tools, interrupt, exec, ui

.. note::
   Accepted 2026-09-30; implementation landed with this record. Fills the
   gap recorded in ``ROADMAP.md`` ("mid-tool hard cancel … Needs ``Shell``
   to expose a registered port-kill handle"): ``Core.Exec`` now observes
   the cooperative stop flag while it waits, so a double-esc ends a
   running command instead of waiting for its deadline.

Context
-------

The double-esc stop is a two-tier seam (``Core.Interrupt``): the session
registers one hard-cancel closure (closing the active provider stream)
and everyone else reads a cooperative flag. The turn loop, the stream,
and `ToolRunner` all check that flag — but only **between** tool calls.
A tool that is already running is invisible to the stop.

That is worst for `shell`: a single command may run up to the 1800s hard
cap, and a hang (`sleep`, a stuck build, a network command that never
returns) means esc appears to do nothing until the deadline. The worker
is parked in ``Exec.collect/5``'s ``receive``; no message arrives for a
silent process, so the ``after`` clause only ever fires at the deadline.
The same holds, more briefly, for `grep`/`glob` (60s) and the file tools.

The ``ROADMAP`` note proposed having `Shell` register a port-kill closure
through the same seam. That is the right instinct but the wrong shape as
literally stated: the cancel map is keyed by session id and holds **one**
closure, so a tool registering its port would evict the stream's closure
— and the tool and the stream are two different moments that must not
clobber each other.

Decision
--------

**1. Cancellation is observed by the executor, not registered by each
tool.** ``Exec.run/5`` already holds the port and owns the wait. It now
reads the session id from the profile and, while waiting, wakes at most
every ``@poll_ms`` (250ms) to check ``Interrupt.requested?/1``. On a stop
it kills the OS process (the same private ``kill/1`` the deadline uses)
and returns ``{:stopped, partial_output}``. No new registration, no key
collision, and one change covers every command — `shell`, `git`, `grep`,
`glob` and the confined file tools, since they all run through ``Exec``.

**2. The session id rides on the sandbox profile.** The tools already put
it there indirectly (``:scratch`` is derived from it); it is now an
explicit ``:session_id`` key. ``Exec`` is the only reader. A profile with
no session id (a bare test, ``Checkpoint``'s internal git bookkeeping,
the ``checkpoint`` restore path) simply keeps its own deadline — the
existing behavior.

**3. A distinct ``{:stopped, output}`` outcome.** It is not a timeout:
the model should read ``STOPPED by the user``, and each tool's error text
says so. The partial output is kept, like a timeout.

**4. The stop/deadline is checked after every chunk AND on the tick.**
Data messages wake the receive immediately; for a *silent* command the
250ms tick is what bounds how long it can outlive the stop. **Corrected
2026-09-30 (review N33):** the first version checked the flag *only* on
the tick, which is exactly backwards — a tick fires only when the
mailbox is quiet for 250ms, so a *chatty* command (a build printing
progress every 20-200ms, `yes`) kept the mailbox full and the flag was
never read: esc was ignored until the deadline (measured: a 20ms-cadence
command with a 60s deadline returned `{:stopped, _}` at **60068ms**), and
a saturating producer could outlive its deadline. `check_stop/5` is now
called from both the data clause and the tick. Measured after the fix:
the same 20ms-cadence stop lands in **<500ms**, and 3s/4s deadlines fire
at 3055/4053ms. The tick remains the floor for a silent command only.

Consequences
------------

- A double-esc now kills a hung `shell` (and `grep`/`glob`/file ops),
  ending the turn at the next tool-result boundary rather than at a
  deadline up to 1800s away.
- The child forwarding in ``esc_stop/1`` (ADR 018 amendment (ii)) gains
  its other half: a child running a `shell` is stopped by the same
  mechanism, because the child session carries its own id and its own
  flag.
- `Checkpoint`'s internal git calls pass the session scope, so they too
  can be stopped; their failure is already swallowed (a warning, not a
  crash), so nothing new is exposed.
- The provider-stream hard cancel is unchanged: it is registered when a
  stream is active and unregistered when it ends, so the executor's flag
  read and the stream's closure never coexist for the same tool call.

Open questions
--------------

1. **A mid-command signal, not just the flag.** ``Exec`` polls the
   cooperative flag; a tool could instead register its own cancel
   closure under a *different* key (tool-scoped) to be killed
   synchronously. The poll is simpler and uniform; revisit only if a
   250ms floor proves too slow.
2. **Subprocess trees.** ``kill -9`` targets the direct OS pid; under the
   bwrap profile ``--die-with-parent`` reaps the namespace, but an
   unconfined shell that daemonizes could orphan a grandchild. Bounded by
   the same deadline as before, so not a regression.
3. **What the model should do next.** A stopped tool returns an error;
   whether the turn should end immediately (it does, via the flag check
   at the next boundary) or let the model react to the partial output is
   settled in favor of ending — the user asked to stop.
