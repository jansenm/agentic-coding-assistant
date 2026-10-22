:orphan:

One boundary: the sandbox enforces reach, and a confining sandbox is required to start
======================================================================================

.. adr::
   :id: 030
   :status: Accepted
   :date: 2026-09-27
   :tags: sandbox, permissions, tools, containment, architecture

.. note::
   **Status: accepted and implemented 2026-09-27.** A deliberate
   architecture correction: it supersedes the ``None`` fallback path of
   ADR 015 for the production case and removes the second boundary the
   native file tools carried.

   **Extended by ADR 046** (2026-10-17): the "test seam" role decision 3
   left ``Sandbox.None`` is retired — the no-op and ``confines?/0`` are
   deleted, so the unconfined mode decision 4 removed is gone seam
   included.

   Shipped in two commits (slices 1–4, then 5–7). ``Tools.FileExec``
   runs the file tools as confined ``cat``/``dd``/``ls``; ``Exec``
   carries stdin and env; session start refuses without confinement;
   ``rg``/``fd`` are required; shell/git are allow-by-default. A live
   bwrap bug surfaced while implementing this: ``hide`` for a FILE used
   ``--ro-bind /dev/null``, which is unreadable under the ``nodev``
   mount of an unprivileged userns; ``--dev-bind`` gives the intended
   empty-image semantic.

   **Amended 2026-10-18 (review N74, P28).** Two details of the ``hide``
   image and of the write path are no longer as this note describes.
   ``hide`` binds the shipped notice instead of a ``/dev/null`` device —
   the device needed the ``--dev-bind`` workaround, and an empty image
   was indistinguishable from absence (ADR 015 carries the amendment).
   And ``write_file`` no longer writes through ``tee``: ``tee`` echoes
   the payload to stdout, which ``Exec`` merges into the error text, so
   a failed write handed the model back its own content; the write is a
   confined ``dd``.

Context
-------

The access-control model grew in two passes, and the second pass never
finished reconciling with the first.

**Pass 1 — path containment (ADR 010).** Native file tools
(``read_file``, ``write_file``, ``edit``, ``list_dir``) check every path
against ``Tools.in_scope?/2`` — the scope root, physically resolved
(symlinks followed). That predicate is their **only** boundary: they do
the I/O themselves, in the BEAM.

**Pass 2 — process confinement (ADR 015).** ``shell`` and ``git`` (and
the ``grep``/``glob`` ripgrep/fd delegations) run as child processes
under bubblewrap, which binds a whole profile (``--ro-bind / /``, the
scope read-write, ``.git`` handling, ``rw``/``ro``/``hide`` mounts,
resource limits). bwrap is *their* only boundary; they carry no path
containment.

The result is a per-tool choice between two incompatible mechanisms,
and neither is complete:

============================  ===========================  ======================
tool                          path containment             process confinement
============================  ===========================  ======================
``read_file`` / ``list_dir``  yes                          no (BEAM I/O)
``write_file`` / ``edit``     yes                          no (BEAM I/O)
``grep`` / ``glob``           only in the Elixir fallback  only in the rg/fd path
``shell`` / ``git``           no                           yes
============================  ===========================  ======================

Three concrete consequences, all observed while designing the file
reference feature (``TODO.md`` B3):

1. **``hide`` is not enforced for native tools at all.** A path the user
   put in ``sandbox.hide`` is invisible to bwrap-bound processes but
   fully readable by ``read_file``. The mount schema is documented as a
   boundary and is not one for half the tools.
2. **The two boundaries disagree by construction.** ``read_file
   /etc/bashrc`` is refused (outside the scope), while ``shell cat
   /etc/bashrc`` succeeds read-only under bwrap. The same reachable
   fact has two answers depending on which tool is asked.
3. **The unconfined fallback is a second operating mode.** When bwrap is
   unavailable (macOS, Windows, hardened hosts), ``Sandbox.impl/0``
   falls back to ``Sandbox.None`` and ``confines?/0`` is false, so the
   gate keeps prompting every ``shell``/``git`` call — ADR 015's
   pre-confinement behaviour, with the whole ``default_for("shell") =
   :ask`` apparatus re-activated. Two modes, two safety narratives, and
   the user cannot tell which one they are in.

The deeper problem: a BEAM-side predicate can never be the boundary for
the arbitrary tools (``shell`` cannot be vetted — ADR 015), and an OS
sandbox can never be the boundary for BEAM I/O (``File.read`` is not a
child process). Trying to pick one mechanism per tool is what produced
the split.

Decision
--------

**There is exactly one boundary for file reachability: the process
sandbox. The BEAM must not perform a scope-relevant filesystem access
itself; a confining sandbox is required for a session to start.**

Everything follows from that:

1. **File tools become confined processes.** ``read_file``,
   ``write_file``, ``edit`` and ``list_dir`` execute their operation as
   a child process through ``Exec`` under the session's sandbox profile,
   exactly as ``shell``/``git`` do today. ``read_file`` is a confined
   ``cat``; ``write_file`` a confined ``dd`` (``Exec`` gains stdin);
   ``edit`` is a confined read, the replacement computed in the BEAM,
   then a confined write; ``list_dir`` a confined ``ls``. There is no
   BEAM-side path predicate left as a boundary.

2. **``hide``/``ro``/``root_ro`` work by construction.** A confined
   ``cat`` on a hidden path reads the notice the sandbox binds there; a
   confined write to a read-only bind fails with ``EROFS``. The mount
   schema is enforced without a second implementation to keep in sync.

3. **No sandbox, no session.** ``Sandbox.impl/0`` no longer silently
   falls back to ``None`` for production. Session start refuses with a
   diagnostic naming what is missing (``bwrap``; unprivileged user
   namespaces) and how to enable it. ``Sandbox.None`` survives only as a
   **test seam** — an explicit, deliberately-unconfined implementation
   the suite selects, never a runtime fallback. **Superseded by ADR 046:**
   the seam is deleted too; a session starts iff a *confining*
   implementation is available.

4. **The unconfined operating mode is deleted.** With confinement
   guaranteed, ``confinement_allows?/2`` is unconditionally true, so the
   ``shell``/``git`` class-default ``:ask`` and its whole apparatus go
   away. ``shell``/``git`` are allow-by-default, bounded by the profile.

5. **``Tools.in_scope?/2`` stops being a boundary.** It remains useful
   as a *discovery* filter (re-checking an engine's returned paths) but
   no tool may rely on it for enforcement; enforcement is the sandbox.
   The BEAM-side ``Containment.walk/3`` is deleted with its
   unconfigured-engine tests: once ``rg``/``fd`` are required there is no
   production caller, and keeping a second traversal path would re-open
   the disagreement this ADR closes.

Why per-call wrapping (not a long-lived helper)
...............................................

The first implementation wraps one process per operation, continuing the
existing ``shell``/``git`` pattern. A long-lived confined filesystem
helper per session (one process, many read/write requests) would make
``edit`` atomic *inside* the sandbox and remove per-call spawn cost, but
it adds lifecycle and makes escalation awkward (mounts are fixed at
spawn). **No optimization without evidence it is needed** — the per-call
form ships first; the helper is an accepted future refinement, not a
current requirement.

Consequences
------------

- **One statement of reach.** The profile (root mode, ``rw``/``ro``/
  ``hide``/``.git``, scratch, network, limits) is the single source of
  truth for every tool. There is no second predicate to keep in parity.
- **``hide`` finally holds for every tool**, which is what makes a
  sensitive-directory exclusion trustworthy.
- **A file reference/autocomplete feature can offer any path the session
  can actually read** (``TODO.md`` B3), because the reach is uniform.
- **``edit`` is no longer atomic within one call** (confined read, BEAM
  transform, confined write). The fail-closed unique-match semantics are
  unchanged; the model-visible behaviour is unchanged. The read/write
  split is accepted as harmless (the BEAM already holds the content for
  the model; the window is no wider in any way that matters under the
  threat model below).
- **Scope-relevant file I/O now costs a process round-trip.** Accepted
  for correctness first; the helper is the escape hatch if it bites.
- **The ``grep``/``glob`` Elixir fallback is a second boundary and must
  go.** Either the reference binaries (``rg``, ``fd``) become required
  (no start without them) or the fallback is reimplemented through
  confined processes. Recorded as an open question; the fallback must
  not remain the unconfined path it is today.
- **macOS and Windows do not run** until an equivalent confining
  implementation exists. This is accepted, not hidden: a tool that
  cannot confine is the wrong tool on that host. The profile abstraction
  stays so ``sandbox-exec``/AppContainer can implement the same
  read/write/hide contract later.

Relationship to ADR 015
-----------------------

ADR 015's threat model stands unchanged and is the reason this is not
security theater: the sandbox defends against **a mistaken agent**, not a
malicious one; data-loss avoidance is the metric, not secrecy. This ADR
does not widen that goal — it removes a *second, incomplete* mechanism
that made the guarantee impossible to state. ADR 015's ``None``
fallback paragraph is **superseded** for production; the rest of ADR 015
(one static profile, mounts as data, escalations for network/``change_vcs``)
is unchanged.

Open questions
--------------

1. **Profile per agent (black-room).** A documentation agent and an
   implementation agent may warrant different ``hide``/``ro`` sets (one
   must not read the other's material). The session-level profile is the
   first shape; per-definition profiles (ADR 017) are the natural
   extension. Wanted, not scheduled.
2. **``grep``/``glob`` fallback — ANSWERED (implemented): require
   ``rg``/``fd``.** A missing binary is a clear error; the Elixir walk
   is gone, and the reference dialect survives only as the filter applied
   to the engine's output.
3. **``edit`` atomicity / the long-lived helper.** Deferred until
   measured need.
4. **macOS/Windows equivalent.** Keep the profile contract identical;
   the implementation is the work.
5. **Test seam shape — ANSWERED (implemented).** A confining test double
   is the suite default (``config/test.exs``); ``SandboxCase.put_sandbox/1``
   restores the env on exit. The refusal path is asserted in
   ``Sandbox.GateTest``. **Revised by ADR 046:** ``Sandbox.None`` no longer
   appears at all; the refusal is driven by an unavailable implementation.
