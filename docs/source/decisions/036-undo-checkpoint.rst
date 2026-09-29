:orphan:

Undo: a git checkpoint per turn, restored by ``/undo``
======================================================

.. adr::
   :id: 036
   :status: Accepted
   :date: 2026-09-29
   :tags: git, sessions, ui, safety

.. note::
   Accepted and implemented 2026-09-29. Answers T8 in the ``TODO.md``
   "rival opencode" list and the "Git is the undo" principle recorded in
   ``ROADMAP.md`` (and chosen over overlay-based protection in ADR 015).
   A checkpoint of the working tree is taken before each turn; ``/undo``
   restores the files to the most recent checkpoint. This is the file
   half of undo; the conversation is untouched. The checkpoint stack is
   bounded by ``checkpoint_depth`` (default 1).

Context
-------

The harness lets the model write files (``write_file``, ``edit``, and
``shell``/``git`` inside the confined profile). Permission prompts are
the *pre*-flight gate; there is no *post*-flight verb. If a turn makes a
mess, the human's only recourse is to remember what changed and undo it
by hand — or to have committed before prompting.

The project already decided the mechanism, twice:

- **ADR 015**: an overlay per single agent was rejected in favour of
  *"Git is the review and undo mechanism"*.
- **ROADMAP**: shell/git run allow-by-default *"with git as the undo
  mechanism"*.

Nothing implements it. The gap is worst exactly when the feature
matters: the owner runs the TUI in a **dirty** working tree (their own
uncommitted work is always present), so "just commit first" is not a
usable answer, and a checkpoint must not disturb that work.

The ``git`` tool (ADR 015 decision 5) already runs with ``git_write:
true`` in the confined profile, and ``Exec.agent_env/0`` makes git
non-interactive. The pieces to snapshot a tree exist; only the
snapshot/restore verbs are missing.

Decision
--------

Recorded owner decisions (2026-09-29):

**1. ``/undo`` restores FILES only.** The working tree is set back to the
most recent checkpoint. The session's context and the display transcript
are untouched — the human can re-prompt with the undo in place. This is
deliberately narrower than opencode's "revert", which also rewinds the
conversation: rewinding context is a separate, riskier operation (it
must also reconcile the agent view, compaction and the display view),
and it is not needed to recover from a bad edit.

**2. A checkpoint is taken automatically before every turn.** No manual
verb to remember. The checkpoint captures the tree as it is at the
moment the user's prompt starts — including their pre-existing
uncommitted and untracked (non-ignored) work — so a restore reproduces
that exact state rather than the last commit.

**3. One step by default, with the option of more.** ``/undo`` restores
the most recent checkpoint and drops it; a second ``/undo`` goes one
further back. The checkpoints form a per-session stack, bounded in depth
(``checkpoint_depth``). "One step" is the UX; the stack is how "more"
costs nothing to add.

**4. The human's uncommitted work is never "cleaned" — only restored.**
Because the checkpoint already contains their dirty state, restoring is
lossless for it. Ignored files (build output, ``.env``) are never
touched by a checkpoint or a restore.

Mechanism
---------

A checkpoint is a git **tree object** plus a private **commit**, written
into a namespaced ref so it never touches ``HEAD``, the index, the
stash, or any branch:

1. ``git add -A`` under a **temporary index**
   (``GIT_INDEX_FILE`` in the session scratch, ADR 022) — captures
   tracked and untracked, honouring ``.gitignore``.
2. ``git write-tree`` → the tree object.
3. ``git commit-tree <tree> -p <previous>`` → a commit (the chain makes
   the stack traversable).
4. ``git update-ref refs/coding-agent/checkpoints/<session-id>/<commit>
   <commit>`` — the commit is in the name, so repeated snapshots never
   collide and the ref anchors the object against ``git gc``.

The whole thing runs confined with the ``git`` tool's profile
(``git_write: true``), so ADR 030 holds: no unconfined git. The temp
index keeps the user's real index exactly as it was.

Restore is the inverse against the checkpoint's tree:

1. ``git read-tree --reset -u <tree>`` — the worktree and index are set
   to the checkpoint's tracked content;
2. every file that is untracked *now* but was not untracked at snapshot
   time is removed (the file the agent added is the main thing undo must
   take back). The comparison is done from the two ``git ls-files
   --others --exclude-standard`` lists, so the human's own untracked
   files stay and ignored files are never listed;
3. drop the checkpoint ref.

The temp index is addressed by its ``/tmp/...`` path (the session scratch
is bound OVER ``/tmp``, ADR 022), never the host path. The one host-side
filesystem work is the harness backing up and restoring the real index
file around ``read-tree`` and unlinking the created files: ``/undo`` is a
*human* action, not an agent tool call, so it runs in the harness process
(ADR 030 confines agent calls, not the human's verbs). The whole thing
runs confined with the ``git`` tool's profile (``git_write: true``).

The state carries the checkpoint stack (ref, tree, commit, timestamp) in
the store's state BLOB, like ``todos`` (ADR 031) — no migration. The ref
namespace is keyed by session id, so a resumed session finds its
checkpoints and can undo across a restart.

Consequences
------------

- ``/undo`` becomes the file-level safety net the ROADMAP promised,
  usable in a dirty tree, without asking the human to commit first.
- A checkpoint costs one confined git pass over the worktree before each
  turn. On a large repo this is real time; it is the price of "always
  available" and is bounded by the same timeout as the git tool.
- The repo gains a ``refs/coding-agent/`` namespace. It is invisible to
  normal git usage and removable (`git update-ref -d`), but it is
  state in the user's ``.git``; the harness prunes it to
  ``checkpoint_depth`` and the session lifecycle verbs should clean it
  when a session is deleted (to be wired with the store verbs).
- **The restore deletes files**: any untracked, non-ignored file under
  the scope root that is absent from the checkpoint is removed. That is
  the intent (take back what the agent created), but it is the sharpest
  edge of the feature and is confined to the scope root, never touching
  ignored files or ``.git``.
- Undo does not rewind the conversation (decision 1). After ``/undo``
  the model still believes it made the change it just lost; the human
  re-prompts. A context rewind is explicitly out of scope and listed
  below.

Open questions
--------------

1. **Rewind the conversation too?** opencode's revert removes the last
   turn from the conversation as well. That needs a "last turn boundary"
   in the agent view (compaction complicates it) and a decision about
   the display view. Not implemented; files-only shipped first.
2. **Redo?** The T-list says "Undo/Redo". Redo means re-applying a
   restored-away state, which the checkpoint stack could answer (keep a
   forward pointer) — but git already has reflog and the user can
   re-prompt. Deferred until asked for.
3. **Checkpoint on every turn, even read-only ones?** A turn that only
   reads files still pays the snapshot. A cheap guard ("this prompt
   contains no mutating intent") cannot be trusted from text; deferring
   the snapshot until the first mutating tool call would race file
   state. Taking it once per turn is the simple, correct choice; a
   future optimisation could skip when the previous turn changed
   nothing.
4. **Large/binary worktrees.** ``git add -A`` hashes every file. A size
   or count guard (skip + warn) may be needed; measured before adding.
5. **Ref cleanup on session delete.** ``Store.delete/1`` /
   ``Store.prune`` should drop the session's checkpoint refs. Wire when
   the feature lands.
