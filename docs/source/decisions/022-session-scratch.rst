:orphan:

Session scratch: a persistent /tmp inside the sandbox
=====================================================

.. adr::
   :id: 022
   :status: Proposed
   :date: 2026-09-20
   :tags: security, tools, shell, sandbox, sessions

.. note::
   Proposed 2026-09-20. Extends ADR 015's confinement (the mount set
   gains one session-scoped bind); does not change the threat model.
   Responds to a live dogfooding finding (``code_review.md`` B7): every
   tool call runs in a fresh namespace whose ``/tmp`` is a fresh tmpfs,
   so the agent cannot build state across calls. Every mechanism below
   was measured on the target machine before being written down.

Context
-------

ADR 015 confines each tool call in its own bubblewrap namespace and
mounts a **fresh tmpfs** at ``/tmp`` for every call
(``Core.Sandbox.Bwrap.argv/3``). A tmpfs dies with its namespace, so
``/tmp`` is ephemeral **per tool call**, not per session.

That breaks a normal agent workflow: run something now, inspect its
output in the next call. Intermediate files, captured command output, a
patch applied and then verified — all the patterns that make ``/tmp``
the natural scratch space of a shell session — fail because the
directory is empty at the start of every call.

The question this ADR settles
-----------------------------

The naive fixes each break an expectation:

- **Bind a host directory over ``/tmp`` and keep it forever.** Then
  ``/tmp`` stops being disposable and accumulates junk across sessions
  and reboots — it lies about its own semantics.
- **Rename the persistent location** (``/scratch``). Then the agent (and
  the user) must learn a new path; ``/tmp`` in their mental model is
  persistent-within-a-session, so nothing should change for them.
- **Mount the host's real ``/tmp`` read-write.** The agent then sees the
  host's shared junk and can delete other programs' files — a widening
  the confinement must not allow.

The standard itself points at the answer: a program that may not use the
literal ``/tmp`` is expected to honour ``$TMPDIR``. Measured facts that
shape the design (target machine, bwrap 0.12.0):

- ``$TMPDIR`` is **unset** in the shell that launches the app here; the
  POSIX fallback ``/tmp`` is therefore always needed.
- ``/tmp`` here is a **tmpfs** (~8 GB), and systemd's
  ``systemd-tmpfiles-clean.timer`` prunes it daily (``q /tmp … 10d``),
  while a reboot empties it entirely. Host ``/tmp`` is never durable.
- ``bwrap --bind <dir> /tmp`` over the existing ``--ro-bind / /`` works
  and persists across two separate bwrap invocations (verified: a file
  written in call 1 is read in call 2, and appears on the host side).
- ``--bind`` and ``--tmpfs`` are mutually exclusive: ``--size`` requires
  ``--tmpfs`` (``bwrap: --size must be followed by --tmpfs``), so the
  current tmpfs size cap has no meaning once ``/tmp`` is a bind.

Decision
--------

**The session gets a scratch directory; the sandbox binds it over
``/tmp``; ``$TMPDIR`` points at ``/tmp`` inside.**

1. **Host location.** ``$TMPDIR/coding-agent/<session-id>/``, falling
   back to ``/tmp/coding-agent/<session-id>/`` when ``$TMPDIR`` is unset
   or empty. This is standard-conforming (we honour a set ``$TMPDIR``)
   and it inherits ``/tmp``'s real lifecycle: gone at reboot, subject to
   the host's tmpfiles policy. We do not invent a new lifetime.
2. **Mount.** ``Bwrap`` binds that directory at ``/tmp`` — replacing the
   per-call tmpfs — and exports ``TMPDIR=/tmp`` in the shell prelude, so
   tools that honour ``$TMPDIR`` and tools that hardcode ``/tmp`` agree
   on one place. The agent sees *only its own* scratch, never the host's
   ``/tmp``; isolation is preserved and the writable set is not widened.
3. **Lifetime = the session.** Created lazily on the first confined
   call; removed when the session is deleted or pruned
   (``Store.delete/1``/``prune``), and moved on ``Store.rename/2``. The
   cleanup is *ours* (the session lifecycle verbs), not an OS timer.
4. **No new size cap in v1.** The per-file ``ulimit -f`` from ADR 015
   still applies. A whole-directory quota is deliberately left open
   (see "Open questions"); where ``$TMPDIR`` is itself a tmpfs the OS
   already bounds it.
5. **``Sandbox.None`` is unchanged.** The no-op runs against the real
   ``/tmp``, which is already persistent for the process's life; the
   ``:scratch`` profile key is ignored there.

Why ``/tmp`` and not a new name
-------------------------------

Because ``/tmp`` *within one session* is exactly what the agent already
assumes, and because the standard already provides the mechanism
(``$TMPDIR``). The change is a correction of the **horizon** — per call
versus per session — not a new concept, a new path, or a new lifetime
policy. The confinement continues to hold: the mount is a private,
per-session directory, so a mistaken ``rm -rf /tmp/*`` destroys only
scratch the session itself produced, and the host's shared ``/tmp`` stays
invisible.

The one honest consequence: a session resumed **after a reboot** finds
an empty scratch — precisely ``/tmp`` semantics, and the correct
expectation.

Data flow (the seam)
--------------------

The only missing wire is the session id in the sandbox scope:

.. code-block:: text

   State.id ─────────────┐
   State.scope_root ─────┤ ToolRunner.scope/3   (today /2: root + mounts)
   State.mounts ─────────┘        │  scope.session_id
                                  ▼
                     Shell.profile/2 · Git.profile/1
                                  │  profile.scratch = host_path
                                  ▼
                     Bwrap.wrap/2   mkdir_p(host_path, 0700)
                                  ▼
                     Bwrap.argv/3   --bind host_path /tmp
                                     (plain --tmpfs /tmp when scratch is nil)
                                  ▼
                     prelude        export TMPDIR=/tmp

``argv/3`` stays **pure** (builds argv, no filesystem access) as it is
today; ``wrap/2``, which already touches the filesystem
(``File.dir?(root)``), creates the scratch directory before launching.
An unset ``:scratch`` keeps today's behaviour exactly, so tests and any
non-session caller are unaffected.

Consequences
------------

- An agent can use ``/tmp`` across calls in one session; the "run, then
  inspect" pattern works.
- The host's shared ``/tmp`` remains invisible and unreachable; the
  writable surface grows by exactly one private directory per session.
- ADR 015's scratch-tmpfs cap is replaced by the session lifetime plus
  ``ulimit -f``; the tmpfs-size figure (``@tmpfs_bytes``) becomes
  meaningful only for the fallback path.
- ``Store.delete/1`` and ``prune`` gain a scratch-removal step and
  ``Store.rename/2`` a move — the existing lifecycle verbs, no new
  surface.
- The ``bwrap_test`` case "scratch tmpfs comes before the scope bind"
  must become "scratch bind (or tmpfs) comes before the scope bind", and
  a new case asserts a scratch bind at ``/tmp`` plus ``TMPDIR`` export.

Open questions (deferred, recorded)
-----------------------------------

- **Directory quota.** ``ulimit -f`` bounds a single file, not the
  scratch total. A per-directory cap (du-check, quota, or a tmpfs-backed
  scratch) is deferred; where ``$TMPDIR`` is a tmpfs the OS already
  bounds it.
- **Surfacing.** Traceability (the confinement thesis in ``ROADMAP.md``)
  would show the effective scratch path and its size in the debug panel;
  not required for the fix.
- **Sharing across sessions.** Deliberately not granted: scratch is
  per-session, matching the isolation boundary.

Implementation order (slice)
----------------------------

1. ``ToolRunner.scope/3`` carries ``session_id``; callers
   (``Session.tool_scope/1``, gate paths) pass ``state.id``.
2. ``Core.Session.Scratch`` (new, tiny): ``path/1`` resolves
   ``$TMPDIR`` with the ``/tmp`` fallback and returns
   ``…/coding-agent/<id>``; ``ensure/1`` creates it ``0700``;
   ``remove/1`` deletes it. One home for the path rule.
3. ``Shell.profile/2`` and ``Git.profile/1`` set ``:scratch`` from the
   scope; ``Bwrap.argv/3`` emits ``--bind <scratch> /tmp`` (or the
   fallback tmpfs when absent) and the prelude exports ``TMPDIR=/tmp``;
   ``Bwrap.wrap/2`` ensures the directory.
4. ``Store.delete/1``/``prune`` call ``Scratch.remove/1``;
   ``Store.rename/2`` moves the directory.
5. Acceptance demo: two separate shell calls in one session — write a
   file to ``/tmp`` in the first, read it in the second (must succeed),
   and confirm the host's ``/tmp`` is not visible from inside.

Measured evidence (target machine, 2026-09-20)
----------------------------------------------

- ``bwrap --ro-bind / / --bind "$S" /tmp …`` : file written inside call 1
  is read inside call 2; host side shows the file; only the scratch dir
  is bound, not the host ``/tmp``.
- With ``export TMPDIR=/tmp`` inside, both ``echo > /tmp/a`` and
  ``mktemp`` land in the bound directory.
- ``bwrap: --size must be followed by --tmpfs`` — the tmpfs size flag is
  incompatible with ``--bind`` and must be dropped on the scratch path.
- ``$TMPDIR`` unset in the launching shell; ``/tmp`` is tmpfs
  (``size=8089756k``); ``systemd-tmpfiles-clean.timer`` active with
  ``q /tmp 1777 root root 10d``.
