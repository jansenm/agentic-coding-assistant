:orphan:

Shell confinement: bound the process, not the command text
==========================================================

.. adr::
   :id: 015
   :status: Proposed
   :date: 2026-09-16
   :tags: security, tools, shell, permissions

.. note::
   Proposed 2026-09-16 — no code yet. It responds to the approval-cost
   finding from live dogfooding, states the threat model explicitly,
   and proposes OS-level process confinement as the shell security
   model. Every mechanism below was measured on the target machine
   (bubblewrap 0.11.2, kernel 7.2.2) before being written down.

Threat model (read this first)
------------------------------

The goal is **a safe agentic coding framework**. "Safe" here means,
precisely:

1. **Safe against a mistaken agent.** A buggy or confused command —
   `rm -rf $VAR` with `VAR` unset, a `>` redirect over the wrong file, a
   runaway loop that fills a disk, an agent "helpfully" downloading a
   toolchain into `/tmp` and compiling it — must not destroy the user's
   work or machine.
2. **NOT safe against a malicious agent.** Defending a capable
   adversary who controls the model output and has tool access is not a
   goal; that fight is unwinnable and pretending otherwise produces
   security theater. Raising the bar enough to stop accidents and
   casual misuse is sufficient. If hiding `~/.ssh` is free, do it; it
   is not the point.
3. **The success metric is data-loss avoidance, not secrecy.**
   Explicitly *not* in scope: hiding `~/.jfrog` before a Maven call, or
   `~/.pgpass` before `psql`. If a legitimate tool needs the
   credential to work, the agent reading it is fine — the tool is
   supposed to have it.

This framing matters because it collapses most of the design space. A
secrets-hiding layer, a command allow-list, and per-command sandbox
selection are all either out of scope or unnecessary.

Context
-------

ADR 010 decision 5 made ``shell`` *always-ask* because a command
allow-list is a footgun (quoting, ``&&`` chaining, subshells). That was
right about allow-lists, and wrong about the consequence: with no path
parameter, ``shell`` cannot be matched by any policy rule
(``Permissions.effective/4`` receives ``""``), so
``default_for("shell") = :ask`` is **not overridable at all**. The
amendment-2 grep deny-list softens one duplicate, but the gate fires
for every other command.

Live evidence (session ``tui-4934``, the ESC-rework review session:
265 messages, 115 tool calls)::

   shell calls, by shape            count
   ------------------------------  ------
   git show/log/status/diff/fetch      46
   grep/rg (grep-tool duplicate)       24
   cat/sed/strings/head/tail           24   (read_file duplicate)
   mix test/compile                     8
   find/ls                              3   (glob/list_dir duplicate)
   genuine mutation (cp, cat >)         2
   other (for-loops, pwd)               5
   ------------------------------------
   total                              112

The blacklist catches 24. The other **88 would each have paused for a
`y`** in one session. A user facing that sets ``shell = allow`` or
reaches for a less nagging tool — the exact rubber-stamp failure the
gate exists to prevent. **The gate currently pays its safety cost
without buying any automation.**

Why vetting command text cannot work (this is settled, not an open
question):

1. **Unbounded** — no enumerable set of CLI tools, aliases, wrappers,
   shell builtins a user *might* run.
2. **Evadable** — ``sh -c '…'``, ``python3 -c '…'``, ``git -c
   alias.x='!rm -rf /' x``, ``base64 -d|sh``, ``$'\\x72\\x6d'``,
   ``find -exec``.
3. **Undecidable in the limit** — "is this command safe?" is a question
   about arbitrary program semantics.
4. **Fragile** — flags/subcommands change across tool versions.

Text-vetting is therefore only ever **UX steering** (as amendment 2
does), never a security boundary. The question changes from *"is this
command safe?"* (unanswerable) to *"what can this process physically
reach?"* (bounded, decidable) — an operating-system question.

Decision (proposed)
-------------------

**Replace per-command approval of ``shell`` with process confinement
via a single static sandbox profile.** ``shell`` runs inside a sandbox
whose filesystem, network and resource access are fixed **before** the
command executes; inside that profile the command is allowed freely,
because its worst-case effect is bounded by construction rather than
guessed from its text. Approval is reserved for the few **escalations**
a profile does not grant (network; writes outside the sandbox), which
are coarse and matchable — not a command grammar.

Crucially, **there is one profile, not one per command.** The earlier
worry ("too many programs write to XDG dirs or elsewhere in ``$HOME``")
is real but does not require per-command logic: it is handled by
*mount layers with different lifetimes*, described below.

### The mechanism: bubblewrap, one static mount set

``bwrap`` is Linux-only and needs unprivileged user namespaces. The
profile:

- **Whole filesystem read-only** (``--ro-bind / /``), so ``/etc``,
  ``/usr``, ``/home`` outside the scope cannot be written or deleted.
- **The scope is an overlay**, not a read-write bind (see below).
- **A disposable ``$HOME``** (tmpfs) with selected subpaths re-bound:
  toolchain state read-only or overlay (``~/.mix``, ``~/.hex``,
  ``~/.gitconfig``; later ``~/.m2``, ``~/.gradle``), cache dirs as
  overlays.
- **Network off** (``--unshare-net``).
- ``--new-session`` (TIOCSTI guard, CVE-2017-5226) and
  ``--die-with-parent``.

### Why the scope overlay is the load-bearing idea

The measured gap: with ``--ro-bind / /`` plus a read-write scope bind,
``rm -rf /`` (from the unset-``VAR`` mistake) cannot touch the system
but **does delete the project** — the actual data-loss case. Measured:

- ``rm -rf /`` under ro-root: system paths error "Read-only file
  system"; host intact.
- ``rm -rf /`` with an rw scope: **scope files deleted.**
- Scope as overlay (``lower`` = the real project, read-only; ``upper``
  = session delta; merged view): agent edits, ``git status`` shows
  ``M app.txt``, ``git commit`` works, a buggy ``rm -rf`` empties only
  the sandbox view — **the real project is byte-for-byte untouched.**

So the project itself is protected the same way the system is, and the
agent's work exists as a reviewable delta that can be promoted
deliberately.

### Lifetime: three layers, not "throw away after each command"

Caches must NOT be discarded per command (that would re-download
Maven/Hex/Cargo artifacts on every invocation). Three lifetimes:

- **Scratch** (one command): tmpfs over ``~/.cache``, shell history
  and ``/tmp``. Discarded when the command returns.
- **Session state** (one session): a tmpfs ``$HOME`` plus read-only or
  overlay binds for toolchain state (``~/.mix``, ``~/.hex``,
  ``~/.gitconfig``; later ``~/.m2``, ``~/.gradle``).
- **Cache overlays** (one session, delta promotable): ``lower`` = the
  real host cache, read-only; ``upper`` = the session delta. Warm
  across commands; the host cache is never written.
- **Scope overlay** (promoted at session end): ``lower`` = the real
  project, read-only; ``upper`` = the session delta.

Measured: across **three separate** bwrap invocations sharing one
overlay upper, artifacts written by call 1 are visible in call 2 and
call 3 with **zero re-downloads**, while the real host cache stays
untouched. Overlayfs with ``--overlay-src <lower> --overlay <upper>
<workdir> <dest>`` was verified (the argument order is
``RWSRC WORKDIR DEST``).

### `.git` protection: read-only for shell, read-write for a git tool

Measured: mounting the real ``.git`` read-only *over* the scope overlay
makes ``git log`` work but ``git commit`` fail
("``index.lock: Read-only file system``") and ``rm -rf .git`` fail
("Read-only file system"), while ordinary file edits still land in the
scope overlay.

This means plain ``shell`` cannot commit. Since ``git`` is the user's
undo mechanism and is worth protecting *and* is the single most common
call (46 of 112), the natural resolution is a **dedicated ``git`` tool**
whose profile leaves ``.git`` read-write (inside the overlay). That is
the one deliberate exception to "everything gets the same profile", and
it is justified three times over: it protects history from accidents,
it removes the largest block of approval prompts, and it makes commits
reviewable as a delta before promotion.

### The escape-hatch gap: git inside a script, and the approval path

A dedicated ``git`` tool only helps when the *agent* calls git. Real
repositories call git from **scripts** — a release script, a build
script, a Makefile target. Measured: running ``./release.sh`` (which
does ``git add``/``commit``) under the shell profile (``.git``
read-only) fails::

   fatal: Unable to create '/tmp/scope/.git/index.lock': Read-only file system

The same script under a profile where ``.git`` is inside the writable
overlay succeeds — commit and tag land in the delta, real repository
untouched (``commits=1, app=v1``). Note this is not a reason to widen
the *default* shell profile: a script is arbitrary code the agent
wrote or found, and the default must stay safe.

**Decision for the gap: an approval path, not a wider default.** The
agent may *request* that a specific script run with git write access.
The escalation is explicit, per invocation, and user-visible:

1. The agent calls ``shell`` with a flag/param such as
   ``git_write: true`` (or an equivalent dedicated "run with git"
   mode). This is **not** inferred from the command text — the agent
   states its intent, the human decides.
2. The gate raises ``:ask`` with the full script shown, exactly like
   today's shell prompt but *rarer*: the default shell path needs no
   prompt, so the only prompts left are network and this git-write
   escalation.
3. On approval, the sandbox mounts ``.git`` writable (inside the
   overlay) for that one invocation. The commit is still a delta,
   promoted at session end like everything else.

This keeps the two properties that matter: the **default** stays
read-only-``.git`` (an agent cannot rewrite history by accident), and
the **legitimate** script path remains possible without the user
resorting to ``shell = allow``. It is consistent with the standing
rule that the human sees the full command on every ``:ask``, and it
composes with the ``git`` tool: both write ``.git`` only through the
overlay, so neither can corrupt the real repository.

### User-configurable mounts (repo and user layer)

Measured that user configuration maps cleanly onto bwrap mounts:

======================  =========================================  =========================
Directive                bwrap translation                          Effect
======================  =========================================  =========================
``ro = [paths]``         ``--ro-bind <p> <p>`` (after overlay)      readable, no write/delete
``hide = [dirs]``        ``--tmpfs <p>``                            empty, invisible, writes discarded
``hide = [files]``       ``--ro-bind /dev/null <p>``                empty/unreadable
======================  =========================================  =========================

Merging follows the existing **non-elevation** rule from the permission
layers: a repo config may only *tighten* (more ``ro``, more ``hide``),
never loosen. The user layer may be stricter than the repo layer, never
the reverse.

Two clarifications to pin down in the schema:

- ``hide`` on a directory yields an **empty writable** tmpfs; writes go
  nowhere. If the intent is "not writable at all", that is ``ro``, a
  distinct directive — do not conflate them.
- Configuration is data, consistent with ADR 007/010.

### The abstraction

A behaviour with swappable implementations, selected like
``Providers.resolve``:

.. code-block:: elixir

   defmodule CodingAgent.Core.Sandbox do
     @callback id() :: atom()
     @callback available?() :: boolean()
     @callback wrap(command :: String.t(), profile :: profile()) ::
                 {:ok, executable :: String.t(), argv :: [String.t()]} | {:error, term()}
   end

- ``Sandbox.Bwrap`` — the real profile above.
- ``Sandbox.None`` — returns ``{:ok, "/bin/sh", ["-c", command]}``,
  i.e. today's behaviour exactly. This makes macOS, Windows, CI
  without userns, and hardened hosts a **no-op fallback**, not a
  special case.

The Shell tool change is then a single call site at the ``Port.open``
construction; ``wrap/2`` is pure and unit-testable, ``available?/0`` is
stubbable.

### Gate rule under the proposal

1. ``shell`` becomes allow-by-default *inside the active profile*.
2. An **escalation** is ``:ask``. There are two: **network access**, and
   **git write access** (the ``git write`` request from the escape-hatch
   gap above, for scripts that commit). Both are coarse booleans the
   agent *states*, never inferred from command text — "may this call use
   the network", "may this script write ``.git``". Escalations are not a
   proxy allow-list.
3. ``shell`` stays ``deny``-able per policy as before.
4. The ``git`` tool has its own profile (``.git`` read-write overlay),
   as does a ``shell`` call approved for git write.

Residual risks (stated, not hidden)
-----------------------------------

- **Kernel/bwrap bugs** — a residual risk, far smaller than any word
  list, not zero. Defence in depth (VCS diff review, protected paths,
  no network by default, resource caps) remains the frame.
- **Platform coverage** — ``bwrap`` is Linux-only. Available in the
  **BaseOS** repos of RHEL/Rocky/AlmaLinux 8 (0.4.0), 9 (0.6.3) and 10
  (0.10.0), and current on Fedora/openSUSE. Hardened hosts may disable
  unprivileged user namespaces (the RHEL 9 DISA STIG, finding V-257816,
  requires ``user.max_user_namespaces=0``; Ubuntu 24.04+ restricts them
  via AppArmor). Re-enabling is one sysctl and root, but on a
  STIG-compliant host it is not permitted — those hosts fall back to
  ``Sandbox.None`` (today's ask-everything), which is acceptable.
- **bwrap version floor.** bwrap 0.11.1 fixed a SIGCHLD disposition bug
  that specifically affects being launched from a process that ignores
  SIGCHLD — **such as the Erlang VM** (upstream issue #705). RHEL 9
  (0.6.3) and RHEL 10 (0.10.0) predate the fix. Detection should
  therefore require a functional probe, not just a version string, and
  the floor must be tested before claiming RHEL 9/10 support.
- **Resource exhaustion** — a fork bomb or disk fill is contained by
  scratch tmpfs but still needs ``nproc``/``fsize``/tmpfs-size caps to
  avoid a local DoS. Named here; exact values to be measured.
- **Promotion is the new trust boundary** — the delta must be reviewed
  before it becomes the real tree. This is intended (it is the user's
  Git-diff undo made explicit) but must be a deliberate UI step, not a
  silent write.
- **Legitimate persistent HOME state** (a login token, an ssh-agent
  socket) does not survive an ephemeral/overlay HOME. That is an
  escalation or an explicit persistent-mount config line, decided by
  the user — not guessed per command.

Open questions for the decision
-------------------------------

1. Is OS confinement with a single static profile the intended
   direction? (It supersedes ADR 010 decision 5's "always-ask".)
2. **Promotion**: automatic at session end with a diff confirmation, or
   an explicit command/menu action?
3. **Resource caps**: include ``nproc``/``fsize``/tmpfs-size in v1, or
   defer?
4. **``git`` tool**: confirm the separate read-write-``.git`` profile
   (and, relatedly, its place in the tool registry)?
5. **Script git write**: confirm the explicit ``git write`` escalation
   for scripts — the agent requests it, the human approves the script
   with git access for that one invocation. Alternatives: a persistent
   per-repo "this script may write .git" allow entry, or requiring the
   user to commit outside the sandbox (rejected — it defeats
   agent-assisted releases).
6. Does an accepted ADR 015 amend ADR 010's shell section (as the
   earlier amendments did) or supersede it?

If accepted, the first code step is intentionally trivial and
behaviour-neutral: the ``Core.Sandbox`` behaviour with
``Sandbox.None`` only, wired at the Shell call site, so the full test
suite stays green before any bwrap code exists.
