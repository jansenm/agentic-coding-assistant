:orphan:

File-lifecycle tools: ``delete_file`` and ``move_file``
=======================================================

.. adr::
   :id: 045
   :status: Accepted
   :date: 2026-10-04
   :tags: tools, files, sandbox, permissions

Context
-------

The agent could edit and create files with native tools (``edit``,
``write_file``) but could not delete or rename one. Both went through
``shell``: ``rm``/``mv`` are allow-by-default inside the scope (ADR 030),
so the capability existed — but it bypassed the native-tool surface the
prompts ask for, it was invisible to a per-path permission entry, and the
agent had to know the flags. Dogfooding hit this twice in one session
(cleaning up review records, renaming a file); AGENTS.md says "prefer the
native tools over their shell equivalents" and there was no native tool
to prefer.

The question is not *whether* the agent may delete or move — it already
may, through ``shell``. The question is whether the operation is
**explicit**: a first-class call with named parameters, behind the
permission gate, in the tool list.

Decision
--------

**1. Two new gated tools, ``delete_file`` and ``move_file``.** They are
confined processes like ``edit``/``write_file`` (ADR 030,
``Tools.FileExec``): ``rm`` and ``mv`` under the session profile. Not a
new boundary — the same one. The BEAM performs no scope-relevant
filesystem access.

**2. Parameters are named after the programs' flags.** The mapping is
mechanical, so the model carries no second vocabulary:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Parameter
     - Flag
   * - ``delete_file.dir``
     - ``rm --dir`` (an empty directory, or any symlink)
   * - ``delete_file.recursive``
     - ``rm --recursive`` (a directory with its contents)
   * - ``move_file.force``
     - ``mv --force`` (overwrite; default is ``--no-clobber``)

``delete_file`` has **no** ``force``: ``rm --force`` means "ignore
nonexistent files" (would turn "no such file" into a silent success,
against the priority on meaningful errors) and "do not preserve root"
(would re-open ``rm -rf /``, which plain ``rm`` refuses). Neither is
wanted, so the axis that remains is ``dir`` × ``recursive``.

**3. ``mv -T`` is always on; the tool states it.** ``to`` is the exact
new path, never a directory to move into. Measured (GNU coreutils 9.12):
``mv -- a b`` with an existing directory ``b`` puts the source at
``b/a``; ``-T`` removes the ambiguity. A move *into* a directory is
written as the full target path. The behavior is named in the tool's
description, because it is a deviation from bare ``mv``.

**4. ``move_file`` refuses an existing destination instead of doing
nothing.** ``mv --no-clobber`` on an existing target exits 0 with **no
stderr** — a "successful" call that moved nothing, which the model cannot
tell from a real move. The tool probes ``to`` first and refuses with a
message naming ``force``; ``--no-clobber`` stays on as a second barrier
(the probe and the process are separate, so the flag is the guarantee,
the probe is the message).

**5. Symlinks follow ``rm``/``mv`` semantics by construction.** No
dereference flag is ever passed, so the underlying programs decide and
the result is exactly theirs — measured: ``rm`` removes the link (never
the target), ``rm --dir`` removes a symlink whatever its target, and
``mv`` moves the link as a link. ``-d``/``-P``/``-L`` are deliberately
not offered.

**6. Allow-by-class (ADR 010 amendment, 2026-09-15).** Both join
``Permissions.@allow_class``: contained (``FileExec`` under the profile)
and reviewable (every landed change sits in the VCS diff). A per-path
policy still tightens them (``[permissions.delete_file] "config/**" =
"ask"``).

**7. The gate evaluates every path a call names.** ``move_file`` has two
(``from`` and ``to``); ``Gate.decision/4`` evaluates both and combines
with ``Permissions.most_restrictive/2`` — the most restrictive wins.
Without this a ``[permissions.move_file] "lib/**" = "deny"`` would not
match (the lookup read only ``path``) and the fallback would allow the
call. One path per call is unchanged: ``[""]``, the previous behavior.

**8. Plan and explore deny both** (``disallowedTools``), like ``edit``
and ``write_file``. The backstop already exists (their ``shell:
read_only`` binds the root read-only, so a removal fails with ``EROFS``),
but the tool list is the stated intent and the two must agree.

Non-goals
---------

- **``copy_file``.** Not built: the dogfooding need was *rename*, never
  *copy*. Deferred (TODO T15), with a note that ``rsync`` would be a
  candidate but is not POSIX-guaranteed where ``cp`` is.
- **``patch_file``** (several exact replacements in one atomic call).
  Same direction, separate slice (TODO T10).
- **Recursion as a silent default.** ``recursive`` is opt-in; a
  non-empty directory without it is ``rm``'s "Directory not empty".
- **``rm``/``mv`` in the shell redirect table.** The table steers
  *read*-duplicates ("use grep"); ``rm -rf _build`` inside a build script
  is legitimate. The native tools are additions, not a redirect.

Consequences
------------

- The agent deletes and renames without leaving the native surface, so a
  policy can address those operations by tool and path. ``shell rm`` still
  works (ADR 030) — this does not narrow it.
- The two tools are always available to the build agent; a read-only
  agent never sees them.
- ``Gate.call_rel_path/2`` became ``call_rel_paths/2`` (plural). The old
  name had no callers outside the gate.

Open questions
--------------

1. **``delete_file`` on a directory without ``recursive``** leans on
   ``rm``'s message. If the model misreads it, a friendlier sentence
   ("the directory is not empty; pass ``recursive: true``") could be
   layered on — not before it bites.
2. **``copy_file`` or ``rsync``?** Reopen only on a real need (T15).
3. **Move across filesystems.** ``mv`` falls back to copy+unlink, which
   for a large tree is slow and non-atomic. Not addressed; the scratch,
   the scope and the mounts are normally one filesystem.
4. **``write_file parents`` vs. a ``mkdir`` tool.** The flag was added
   because a write into a missing directory is the common case and the
   bare ``tee`` message named neither the cause nor the fix. A full
   ``mkdir`` tool is still absent; add it when creating an EMPTY
   directory (with no file to put in it) is actually needed.
