:orphan:

Confining-only: no unconfined seam, and the sandbox owns its scratch mapping
============================================================================

.. adr::
   :id: 046
   :status: Accepted
   :date: 2026-10-17
   :tags: sandbox, permissions, containment, architecture, testing

.. note::
   **Status: accepted and implemented 2026-10-17.** Completes ADR 030:
   with confinement already a session-start precondition, the last
   non-confining implementation (``Sandbox.None``) and the capability
   question it existed to answer (``Sandbox.confines?/0``) are deleted.
   The one place that assumed a mount layout — the checkpoint temp index,
   which hardcoded the confined path ``/tmp/checkpoint-index`` — now asks
   the sandbox for the path a confined process sees.

   **Amended 2026-10-25 (review P13, owner ruling).** bwrap is a HARD
   dependency, and the suite says so instead of skipping: ``test_helper.exs``
   probes ``Bwrap.check/0`` before ``ExUnit.start/0`` and raises with the
   probe's reason when it is unusable. The four bwrap integration files used
   to turn "no bwrap" into ``:ok`` inside the test body, so their
   ``N passed`` was indistinguishable from ``0 checked`` — on a host that is
   now unsupported, the run refuses rather than reports. ``config/test.exs``
   still selects the confining pass-through double for the *profile*; the
   dependency is on the binary, not on running every test under it.

Context
-------

ADR 030 made confinement a precondition and kept ``None`` as a *test
seam*; ADR 015 had introduced ``confines?/0`` as "the gate's question",
with ``None.confines?/0 == false``. Two things then went stale.

**The opt-out had already stopped working.** ``Session.init/1`` refuses to
start unless ``Sandbox.confines?/0`` is true, and ``None`` is the only
implementation that returns false. A session started under ``None``
therefore always refused; ``None`` survived only as a subject of its own
unit tests and as a direct ``wrap/2`` call in one test. The "explicit,
deliberately-unconfined" implementation ADR 015/030 described had ceased
to be an operating mode.

**The tests assumed a mount the code hardcoded.** The suite runs under a
confining *pass-through* double (``config/test.exs``), which binds nothing
over ``/tmp``. ``Checkpoint`` exported ``GIT_INDEX_FILE=/tmp/checkpoint-index``
— the path a *confined* git sees — while creating and removing the *host*
file ``<scratch>/checkpoint-index``. Under bwrap those are one file (the
session scratch is bound over ``/tmp``, ADR 022); under the double they are
not, so ``/tmp/checkpoint-index`` was a single real file for the whole run
and any two concurrent checkpoints corrupted each other. The checkpoint
suites could not run ``async``. A second source of the same class: the host
path was derived from the ``session_id`` argument, but the bind from
``scope.session_id``.

Decision
--------

1. **Every implementation confines; there is no capability to query.**
   ``Sandbox.None`` is deleted, and with it the ``confines?/0`` callback,
   ``Sandbox.confines?/0``, the resolver branches that special-cased a
   non-confining module, and the ``:root_ro_unavailable`` refusal path. A
   ``Sandbox`` implementation is usable iff it is ``available?/0``;
   session start refuses when none is.

2. **The sandbox owns the host→sandbox path mapping.** A new optional
   callback ``visible_path/2`` (identity by default), its dispatcher
   ``Sandbox.visible_path/2``, and ``Sandbox.Bwrap.visible_path/2`` (the
   session scratch → ``/tmp``, the inverse of its ``--bind … /tmp``).
   Callers that must hand a host file to a confined process ask the
   sandbox; nothing hardcodes ``/tmp``.

3. **One source of truth for the scratch.** ``Checkpoint`` builds a single
   ``Git.profile/1`` from the session id the checkpoint belongs to, so the
   bind and the temporary index cannot name different scratches.

Consequences
------------

- **The unconfined mode is gone entirely, seam included.** On a host
  without a confining sandbox (macOS, Windows, a hardened Linux) a session
  refuses to start with the diagnostic; there is no ``None`` to select.
  Because ``None`` could not start a session anyway, nothing usable is
  lost.
- **Correct by construction under any sandbox.** A pass-through
  implementation — a test double, or a future platform whose profile does
  not remap ``/tmp`` — reports the host path, and ``Checkpoint`` removes
  exactly the file git wrote.
- **The checkpoint suites run ``async``.** The suite's sync section
  shrinks accordingly.
- **``root_ro`` is a grant the sandbox honours, with no refusal path.**
  An implementation that cannot make the root read-only must refuse at the
  boundary; none exists that cannot, so the error branch is deleted.
- **Platform ports implement the same two things.** ``sandbox-exec``
  (macOS) or AppContainer (Windows) implement the profile contract and, if
  they bind differently — or not at all — ``visible_path/2``.

Relationship to earlier records
-------------------------------

- **ADR 030 decision 3** kept ``None`` as a test seam; **superseded** — the
  seam is deleted, so decision 4's "the unconfined operating mode is
  deleted" now holds without exception.
- **ADR 015**'s ``confines?/0`` callback and ``None`` bullet, **ADR 010**'s
  ``:root_ro_unavailable`` refusal, **ADR 017**'s "refuses rather than
  degrades" fallback, **ADR 022**'s "``Sandbox.None`` is unchanged" and
  **ADR 038**'s parenthetical are all annotated as superseded in place.

Open questions
---------------

1. **Scratch cleanup for temp indexes.** The checkpoint temp index is not
   removed after the tree is written; it is replaced by the next snapshot
   and reclaimed with the session scratch when the session is deleted. One
   small file per live session, not a problem today — named for the
   record.
