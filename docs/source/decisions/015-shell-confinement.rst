:orphan:

Shell confinement: bound the process, not the command text
==========================================================

.. adr::
   :id: 015
   :status: Accepted
   :date: 2026-09-17
   :tags: security, tools, shell, permissions

.. note::
   Accepted 2026-09-17 — no code yet. It responds to the approval-cost
   finding from live dogfooding, states the threat model explicitly, and
   replaces ADR 010 decision 5 ("shell is always-ask") with OS-level
   process confinement. Every mechanism below was measured on the target
   machine (bubblewrap 0.11.2, kernel 7.2.2) before being written down.

Threat model (read this first)
------------------------------

The goal is **a safe agentic coding framework**. "Safe" here means,
precisely:

1. **Safe against a mistaken agent.** A buggy or confused command —
   ``rm -rf $VAR`` with ``$VAR`` unset, a ``>`` redirect over the wrong
   file, a runaway loop that fills a disk, an agent "helpfully"
   downloading a toolchain into ``/tmp`` and compiling it — must not
   destroy the user's work or machine.
2. **NOT safe against a malicious agent.** Defending a capable adversary
   who controls the model output and has tool access is not a goal; that
   fight is unwinnable and pretending otherwise produces security
   theater. Raising the bar enough to stop accidents and casual misuse
   is sufficient. If hiding ``~/.ssh`` is free, do it; it is not the
   point.
3. **The success metric is data-loss avoidance, not secrecy.**
   Explicitly *not* in scope: hiding ``~/.jfrog`` before a Maven call, or
   ``~/.pgpass`` before ``psql``. If a legitimate tool needs the
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
amendment-2 grep deny-list softens one duplicate, but the gate fires for
every other command.

Live evidence (session ``tui-4934``, the ESC-rework review session: 265
messages, 115 tool calls)::

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
``y``** in one session. A user facing that sets ``shell = allow`` or
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

Decision
--------

**Replace per-command approval of ``shell`` with process confinement via
a single static sandbox profile.** ``shell`` runs inside a sandbox whose
filesystem, network and resource access are fixed **before** the command
executes; inside that profile the command is allowed freely, because its
worst-case effect is bounded by construction rather than guessed from its
text. Approval is reserved for the few **escalations** a profile does not
grant (network; writing ``.git``), which are coarse and matchable — not a
command grammar.

Crucially, **there is one profile, not one per command.** The earlier
worry ("too many programs write to XDG dirs or elsewhere in ``$HOME``")
is real but is handled by *mounts*, not by per-command logic: the writable
set is data the user configures (see below).

This decision **supersedes ADR 010 decision 5**. It keeps decision 5's
insight (a command allow-list is a footgun) and removes its cost.

### The mechanism: bubblewrap, one static mount set

``bwrap`` is Linux-only and needs unprivileged user namespaces. The
profile:

- **Whole filesystem read-only** (``--ro-bind / /``), so ``/etc``,
  ``/usr`` and every ``$HOME`` path not explicitly opened cannot be
  written or deleted.
- **The project is a plain read-write bind** (``--bind <repo> <repo>``).
  This is the lightweight model: there is **no overlay and no delta**.
  A formatter, a codegen step or a build writes into the real tree
  immediately, exactly as today. ``_build``/``deps``/``target`` are
  covered by the same bind (they live in the repo).
- **Toolchain caches are explicit read-write binds** (``~/.hex``,
  ``~/.mix``, ``~/.m2``, ``~/.gradle``, ``~/.cache`` …), so they are
  shared with the host exactly as they are today — no re-download per
  session. This is the largest piece of initial work and the reason the
  writable set must be user-configurable (see the mount schema).
- **``.git`` is re-bound read-only over the project bind** for plain
  ``shell`` (see below).
- **Scratch** ``/tmp`` is a tmpfs, discarded when the command returns.
- **Network off** (``--unshare-net``).
- **Resource caps** (``ulimit -u/-f/-t`` set in an ``sh`` prelude that
  ``exec``\\ s the command, inside the namespace) — in v1 (decision 3).
- ``--new-session`` (TIOCSTI guard, CVE-2017-5226) and
  ``--die-with-parent``.

### Why there is no overlay: Git is the delta

An earlier design wrapped the project in an overlayfs (lower = real
project, read-only; upper = session delta) so that a buggy ``rm -rf``
inside the allowed area could not touch the real tree. That is
**rejected**: the only thing such an overlay buys over Git is protection
of *never-committed untracked files*, and its cost is re-implementing —
worse — what Git already does (ignore rules, rename detection, binary
handling). A hand-rolled delta viewer would either miss those cases or
duplicate them exactly.

The lightweight model therefore makes the project writable and lets Git
be the review and undo mechanism, unchanged:

- A mistaken write or delete of a **tracked** file is recovered with
  ``git checkout`` / ``git diff`` as it is today.
- A **newly created** file survives immediately (formatter output,
  codegen, ``mix test`` artifacts).
- The one accepted loss: a never-committed **untracked** file that the
  agent deletes is not recoverable through Git. This is a small, honest
  residual risk, and it is the deliberate price of not maintaining a
  parallel delta mechanism.

Measured: with the project as a plain rw bind and ``.git`` read-only,
``echo … > src/a.ex`` and ``echo … > generated.txt`` both persist in the
real repository, while ``git commit`` fails
(``index.lock: Read-only file system``). No merge, no promotion step.

### `.git` protection: read-only for shell, read-write for a git tool

Measured: re-binding the real ``.git`` read-only *over* the rw project
bind makes ``git log``/``git status`` work but ``git commit`` fail
("``index.lock: Read-only file system``") and ``rm -rf .git`` fail
("Read-only file system"), while ordinary file edits still land in the
real tree.

This means plain ``shell`` cannot commit. Since ``git`` is the user's
undo mechanism and is worth protecting *and* is the single most common
call (46 of 112), the resolution is a **dedicated ``git`` tool** whose
profile leaves ``.git`` read-write (decision 4). That is the one
deliberate exception to "everything gets the same profile", justified
three times over: it protects history from accidents, it removes the
largest block of approval prompts, and it keeps commits an explicit,
reviewable agent action.

### The escape-hatch gap: git inside a script, and the approval path

A dedicated ``git`` tool only helps when the *agent* calls git. Real
repositories call git from **scripts** — a release script, a build
script, a Makefile target. Measured: running ``./release.sh`` (which
does ``git add``/``commit``) under the shell profile (``.git``
read-only) fails::

   fatal: Unable to create '…/.git/index.lock': Read-only file system

The same script under a profile where ``.git`` is read-write succeeds,
committing normally. Note this is not a reason to widen the *default*
shell profile: a script is arbitrary code the agent wrote or found, and
the default must stay safe.

**Decision for the gap: an approval path, not a wider default**
(decision 5). The agent may *request* that a specific script run with git
write access. The escalation is explicit, per invocation, and
user-visible:

1. The agent calls ``shell`` with a flag/param such as
   ``git_write: true`` (or an equivalent dedicated "run with git" mode).
   This is **not** inferred from the command text — the agent states its
   intent, the human decides.
2. The gate raises ``:ask`` with the full script shown, exactly like
   today's shell prompt but *rarer*: the default shell path needs no
   prompt, so the only prompts left are network and this git-write
   escalation.
3. On approval, the sandbox re-binds ``.git`` read-write for that one
   invocation.

This keeps the two properties that matter: the **default** stays
read-only-``.git`` (an agent cannot rewrite history by accident), and the
**legitimate** script path remains possible without the user resorting to
``shell = allow``. It is consistent with the standing rule that the human
sees the full command on every ``:ask``.

### User-configurable mounts (repo and user layer)

The writable set is data, consistent with ADR 007/010. Directives:

======================  =========================================  ===============================
Directive                bwrap translation                          Effect
======================  =========================================  ===============================
``rw = [paths]``         ``--bind <p> <p>``                         shared with host, writable
``ro = [paths]``         ``--ro-bind <p> <p>`` (after ``rw``)       readable, no write/delete
``hide = [dirs]``        ``--tmpfs <p>``                            empty, invisible, writes discarded
``hide = [files]``       ``--ro-bind /dev/null <p>``                empty/unreadable
======================  =========================================  ===============================

The default profile ships the cache paths (``~/.hex``, ``~/.mix``,
``~/.m2``, ``~/.gradle``, ``~/.cache`` …) in ``rw``; the user layer may
add more. Merging follows the existing **non-elevation** rule from the
permission layers: a repo config may only *tighten* (more ``ro``, more
``hide``, fewer ``rw``), never loosen. The user layer may be stricter
than the repo layer, never the reverse.

Two clarifications to pin down in the schema:

- ``hide`` on a directory yields an **empty writable** tmpfs; writes go
  nowhere. If the intent is "not writable at all", that is ``ro``, a
  distinct directive — do not conflate them.
- ``rw`` is the sensitive directive: it is the one that *adds* reach. It
  can only ever come from the built-in default profile (caches) and the
  user layer, never from a repo config, so a checked-out repository
  cannot widen its own sandbox.

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
- ``Sandbox.None`` — returns ``{:ok, "/bin/sh", ["-c", command]}``, i.e.
  today's behaviour exactly. This makes macOS, Windows, CI without
  userns, and hardened hosts a **no-op fallback**, not a special case.

The Shell tool change is then a single call site at the ``Port.open``
construction; ``wrap/2`` is pure and unit-testable, ``available?/0`` is
stubbable.

### Gate rule

1. ``shell`` becomes allow-by-default *inside the active profile*.
2. An **escalation** is ``:ask``. There are two: **network access**, and
   **git write access** (the ``git write`` request above, for scripts
   that commit). Both are coarse booleans the agent *states*, never
   inferred from command text — "may this call use the network", "may
   this script write ``.git``". Escalations are not a proxy allow-list.
3. ``shell`` stays ``deny``-able per policy as before.
4. The ``git`` tool has its own profile (``.git`` read-write), as does a
   ``shell`` call approved for git write.

Residual risks (stated, not hidden)
-----------------------------------

- **Kernel/bwrap bugs** — a residual risk, far smaller than any word
  list, not zero. Defence in depth (Git diff review, protected paths, no
  network by default, resource caps) remains the frame.
- **Never-committed untracked files** — deleting one is not recoverable
  through Git. Accepted, and the reason the overlay was dropped.
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
  avoid a local DoS. Caps are in v1; exact values to be measured.
- **Legitimate persistent HOME state** (a login token, an ssh-agent
  socket) is not writable unless it is in the configured ``rw`` set or
  explicitly escalated. That is a config line decided by the user, not
  guessed per command.

Decisions taken (2026-09-17)
----------------------------

1. **Direction** — OS confinement with one static profile. Yes.
2. **Promotion** — *none*: no overlay, no delta, no merge. The project is
   a plain rw bind; Git is the review and undo mechanism.
3. **Caches** — shared read-write with the host, as today, and
   user-configurable (the ``rw`` directive). The largest initial work.
4. **Resource caps** — in v1 (``nproc``/``fsize``/tmpfs size).
5. **``git`` tool** — yes, a dedicated tool with a read-write-``.git``
   profile.
6. **Script git write** — explicit per-invocation ``git_write``
   escalation; default stays read-only-``.git``.
7. **Relation to ADR 010** — ADR 015 **supersedes** decision 5.

Implementation order
--------------------

The first code step is intentionally trivial and behaviour-neutral: the
``Core.Sandbox`` behaviour with ``Sandbox.None`` only, wired at the Shell
call site, so the full test suite stays green before any bwrap code
exists. Then ``Sandbox.Bwrap`` with the functional probe, then the
``rw``/``ro``/``hide`` mount schema, then the dedicated ``git`` tool and
the ``git_write`` escalation.
