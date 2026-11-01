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
     - ``rm --dir`` (an empty directory; refused for a file or a symlink)
   * - ``delete_file.recursive``
     - ``rm --recursive`` (a directory with its contents)
   * - ``move_file.force``
     - ``mv --force`` (overwrite; default is ``--no-clobber``)

**2a. A flag whose shape does not match is refused (amendment
2026-10-18, review P28).** ``rm --dir`` removes a plain file too —
measured (GNU coreutils 9.12): exit 0 without a message — so the tool
probes the shape through a confined ``ls -dF`` and accepts only a real
directory under ``dir: true``. A symlink is not one, whatever it points
at: ``rm`` removes the link and needs no flag for it. ``recursive:
true`` is exempt — alone or beside ``dir: true`` it means the same for
every shape. The ``-F`` marker decides and the name never does, because
a name may itself end in ``@`` or ``/`` (the earlier check asked whether
``path/.`` resolves, which cannot see the difference between a directory
and a symlink to one).

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
not offered. The one place where the link's type matters is decision 2a:
`dir: true` on a link is refused, because the flag is unnecessary for it
and a "yes" would be a guess about a path ``rm`` will not dereference.

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
   layered on — not before it bites. The same message question for a
   flag that names the wrong shape is **answered** (decision 2a): there
   the program said nothing at all, so the tool must.
2. **``copy_file`` or ``rsync``?** Reopen only on a real need (T15).
3. **Move across filesystems.** ``mv`` falls back to copy+unlink, which
   for a large tree is slow and non-atomic. Not addressed; the scratch,
   the scope and the mounts are normally one filesystem.
4. **``write_file parents`` vs. a ``mkdir`` tool.** The flag was added
   because a write into a missing directory is the common case and the
   bare program message named neither the cause nor the fix. A full
   ``mkdir`` tool is still absent; add it when creating an EMPTY
   directory (with no file to put in it) is actually needed.
5. **The write program.** ``write_file`` writes through a confined
   ``dd`` (amendment 2026-10-18, review P28). ``tee`` was the first
   choice and failed on its one job: it echoes stdin to stdout, and
   ``Exec`` merges stderr into stdout, so the error text for a failed
   write arrived with the whole payload behind it. If a POSIX program
   writes stdin with quieter semantics than ``dd``'s ``of=``, it is
   welcome to replace it — measured against the same four cases
   (missing parent, ``EROFS`` bind, an existing file, an empty write).

Amendment 2026-11-01: ``move_region``, and why the region is not addressed by line numbers
------------------------------------------------------------------------------------------

Split work is the case this ADR did not cover: ``delete_file`` and
``move_file`` move whole PATHS, and nothing moved a BLOCK of one file into
another. The gap was filled by hand, three times in one session, with
``sed -i 'N,Md'`` — and every deletion shifted the numbers for the next, so
the map had to be re-derived after each step. The damage from one bad
range surfaced as a compile error about an undefined function several
hundred lines from the deleted region. That is the dogfooding incident
this amendment answers (a P-level feedback point: *no region-move
primitive, and the resulting damage is misattributed*).

**One new gated tool, ``move_region``**, split the way ``Session.Gate`` /
``Session.ToolRunner`` are: the computation is
``Core.Region`` (pure, no filesystem, 22 unit tests) and
``Tools.MoveRegion`` is the confined I/O around it.

**1. The region is addressed by ANCHOR TEXT, not by line numbers.** The
caller that wants a move has just read the code, so it has the anchor;
only a caller with a stale file has line numbers. ``from`` must occur
exactly once; ``to`` is looked for at or after it (so ``"end"`` — a word
that occurs hundreds of times in an Elixir file — is usable as a region
end, while the region itself stays unambiguous). An ambiguous anchor is an
error that NAMES the lines (``3 matches for the `from` anchor on lines 2,
4, 6``), the rule ``edit`` already states and ``dd10698`` measured.

**2. Line-number hints are refused, and the reason is measured.** A full
scan for both anchors plus the newline count that produces those line
numbers costs **1.0 ms** on a 208 147-byte file (``lib/coding_agent/ui/tui.ex``,
100 iterations). A hint could not move that work, only reorder it, and the
whole-file scan is needed anyway to prove uniqueness. A hint would therefore
be a new parameter that can be stale, in exchange for nothing. If one is
ever added it must be a DISAMBIGUATOR (``occurrence: 3``), verified against
the match list — a different thing, and not in this version.

**3. Four positions, and ``:begin`` was missing from the first draft.**
``:begin``, ``:end``, ``{:before, anchor}``, ``{:after, anchor}`` — an
editor's four moves. The JSON schema cannot carry the tuple, so the string
spellings ``":begin"`` / ``":end"`` / ``"before: <anchor>"`` /
``"after: <anchor>"`` are parsed by the tool, with the term form accepted
too.

**4. A same-file move resolves its position in the ORIGINAL text and
refuses a point inside the region, closed interval.** ``s <= o <= e`` — and
the closed end matters: ``o == e`` is ``{:after, <the region's own last
line>}``, the commonest no-op of all, and a half-open test let it through
as a silent success. The interval also covers ``:begin`` on a region at
offset 0, ``{:before, <the start anchor>}`` and ``:end`` on a region that
ends the file. A move that would not change the file is an error.

**5. The write order is destination-first, and the reason is space.** A
cross-file move makes two writes and they cannot be atomic (``FileExec``
has no transaction). Writing the destination first leaves a crash
DUPLICATED — visible, one keystroke away — instead of LOST, which is what
writing the source first would risk. The second half is that the
destination write is the only one that GROWS the filesystem: the source
write then shrinks by the region, so ``ENOSPC`` cannot reach the step whose
failure would be hard to undo. The destination's original bytes are held in
the BEAM for the rollback (a destination that did not exist before is
removed again, which is the exact undo of creating it). A same-file move
cannot be split into two writes at all, so it writes a temporary file
BESIDE the target — same filesystem, so the rename is atomic; a temp in the
scratch would turn ``mv`` into copy+unlink — and renames over the original.

**6. Both results must parse (``.ex``/``.exs``), or the move is refused.**
``Code.string_to_quoted/1`` on each result. This is precisely the check
whose absence let a half-deleted block reach the compiler. It is a syntax
check only, and both the tool's result message and the module doc say so: a
moved function whose ``alias`` stayed behind still parses, and ``mix
compile`` is the real check.

Consequences:

- ``Region`` is pure and the interesting half (anchors, ambiguity, offsets)
  is unit-testable without a sandbox; ``MoveRegion`` is the boring half.
- Both paths go to the gate, the rule ``move_file`` already documents: a
  deny on either end refuses the call. ``move_region`` joins
  ``Permissions.@allow_class`` with the other contained writes.
- ``dry_run: true`` reports the anchor lines and the region size and writes
  nothing, so the tool is safe to call while orienting.
- The move does not FORMAT (``mix format`` is the caller's next step) and
  does not carry aliases, imports or module attributes with the region.
  Deciding which ones a moved block still needs is semantic, not textual.
