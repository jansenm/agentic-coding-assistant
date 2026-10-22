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

   **Partially superseded by ADR 030** (2026-09-27): the ``None``
   fallback path, the unconfined operating mode, and the tool-level
   split it left standing (file tools doing BEAM I/O with a path
   predicate) are replaced by "one boundary": the sandbox enforces reach
   for EVERY tool, and a confining sandbox is a session-start
   precondition. The threat model, the bwrap profile, the mount schema
   and the escalation decisions below stand unchanged.

   **Also superseded by ADR 046** (2026-10-17): the ``confines?/0``
   callback and the ``Sandbox.None`` bullet below are gone — confinement
   is a precondition, not a capability to query.

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

The redirect table catches 24 (the amendment-2 mechanism; it was named
a "blacklist" until the 2026-10-13 amendment to ADR 010). The other **88
would each have paused for a
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
   ``change_vcs: true`` (or an equivalent dedicated "run with git" mode).
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
``hide = [dirs]``        ``--ro-bind <notice>/ <p>``                present, not readable
``hide = [files]``       ``--ro-bind <notice>/README.txt <p>``      present, not readable
======================  =========================================  ===============================

The default profile ships the cache paths (``~/.hex``, ``~/.mix``,
``~/.m2``, ``~/.gradle``, ``~/.cache`` …) in ``rw``; the user layer may
add more. Merging follows the existing **non-elevation** rule from the
permission layers: a repo config may only *tighten* (more ``ro``, more
``hide``, fewer ``rw``), never loosen. The user layer may be stricter
than the repo layer, never the reverse.

Two clarifications to pin down in the schema:

- ``hide`` makes the path **present and read-only**, bound to the
  shipped notice (``priv/coding-agent/sandbox/README.txt``). Two earlier
  images were tried and dropped: an empty tmpfs for a directory and
  ``/dev/null`` for a file. Both left the agent unable to tell a hidden
  path from a missing one, which is the one thing ``hide`` must
  communicate — the user decided the path is invisible, and the agent
  has to know that rather than conclude its information is stale. The
  notice says so in words, and being read-only the path cannot be
  written: nothing evaporates silently. See the amendment below.
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
     @callback confines?() :: boolean()
     @callback check() :: :ok | {:error, reason}   # optional
     @callback wrap(spec(), profile()) ::
                 {:ok, executable :: String.t(), argv :: [String.t()]} | {:error, term()}
   end

- ``Sandbox.Bwrap`` — the real profile above.
- ``Sandbox.None`` — returns ``{:ok, "/bin/sh", ["-c", command]}``. A
  deliberate no-op for the **test seam and an explicit opt-out**;
  **superseded by ADR 030**: it is no longer an automatic fallback, and
  a session refuses to start without confinement.

.. note::
   **Superseded by ADR 046** (2026-10-17). ``Sandbox.None`` is deleted and
   the ``confines?/0`` callback is gone with it: it could only subtract
   capability, because confinement is a session-start precondition. The
   behaviour carries ``visible_path/2`` (the host→sandbox path mapping) in
   its place.

``confines?/0`` was distinct from "a sandbox is configured": it was the
gate's question (``None.confines?`` was false). **ADR 030 supersedes**
``configured/0``/``impl/0``'s silent fallback: an unavailable confining
implementation now yields ``nil`` and a refusal, never ``None``.

**Bwrap is the shipped default.** ``config/config.exs`` sets
``sandbox: Sandbox.Bwrap``; the test suite pins a confining test double
so a run behaves identically on a machine without bwrap. **ADR 030
supersedes the fallback paragraph**: where a confining sandbox is
requested but cannot run, ``Application.start/2`` logs one warning with
the reason (missing binary, disabled unprivileged user namespaces) and
the first session start REFUSES with that reason — an unconfined
production mode no longer exists. The check is a *functional probe*
(``Bwrap.check/0`` launches a trivial bwrap command from the BEAM), not a
version string, because bwrap < 0.11.1 has the SIGCHLD bug that only
manifests when the parent ignores SIGCHLD — which the Erlang VM does.

The command is a **spec**: ``{:shell, command}`` or
``{:exec, file, args}``. The ``git`` tool uses the exec form, so its
argument list is handed to git as argv and is **never re-parsed by a
shell** — otherwise ``["log", "; touch marker"]`` would inject. Inside
bwrap the exec form runs as ``sh -c 'ulimit …; exec "$@"' sh git <args>``;
the shell exists only to apply the rlimits, and ``exec`` replaces it
without re-parsing. The port loop (spawn, deadline, kill, truncate) lives
once in ``Core.Exec``, the single ``Sandbox.wrap`` call site.

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
5. **The ``git`` tool is allow-by-default too** under confinement — git's
   subcommand space is bounded, but classifying read vs write subcommands
   was **rejected**: the goal is to protect against dumb mistakes, not to
   re-review every git call, and a user who finds git too risky can write
   ``[permissions.git] "*" = "ask"`` (or use another VCS). An explicit
   policy entry always wins over the class default, for both tools.

Amendment 2026-10-17: one escalation module, and the git tool's network
-----------------------------------------------------------------------

The gate decided which tool could escalate by matching the string
``"shell"`` in four places, and a tool's escalation keywords were a copy in
the code that read them. Adding the network to the ``git`` tool would have
meant a fifth and sixth copy, so the semantics moved to one module first:

* ``Tools.Escalation`` owns the keyword list (``all/0``), the schema reader
  (``of/1``), the coarse-boolean reader (``requested/2``, ``granted?/2``),
  the reason (``reason/1``) and the verdict (``verdict/2``).
* Each tool publishes its own parameter schema (``Shell.parameter_schema/0``,
  ``Git.parameter_schema/0``). The gate reads the keywords **the tool
  declares** instead of assuming which ones apply, so a keyword a tool does
  not offer is not an escalation — it can never demand a reason for a file
  tool, and cannot widen a profile that has no such grant.
* ``Shell`` keeps its API as thin delegations (``escalations/1``,
  ``escalated?/1``, ``reason/1``, ``escalation_verdict/1``); ``Shell`` and
  ``Git`` share one ``truthy?/1`` instead of two.

**The ``git`` tool gains ``network`` (and ``reason``).** The network is the
one grant left for it: ``.git`` write is unconditional (decision 4), so
``change_vcs`` on a git call is *not* an escalation the tool offers, and
stating it costs no keystroke. The parameter is what makes ``fetch``,
``clone``, ``pull`` and ``push`` possible at all. Measured, before it:

``fatal: Could not read from remote repository`` with no network namespace,
i.e. a host-resolution error naming neither the cause nor the way out — so
``Git.network_verdict/1`` answers a remote subcommand that did not ask with
"retry with `network: true` and a `reason`". The list is not a boundary and
is not exhaustive; it is the message (an unlisted subcommand, or a script
driving git, fails at the namespace as before). ``push`` additionally needs
credentials, which the confinement does not bind: ``fetch`` is the case
that works end to end.

**Where the network can come from is the call, never the profile shape.**
``Git.profile/1`` became ``profile/2`` with ``args`` defaulting to ``%{}``
— because ``Checkpoint.git/4`` shares that function for its internal index
work, and a default that read the profile rather than the call would have
silently given the checkpoint path the network. ``Git.profile(scope)`` is
still exactly the old shape: ``.git`` writable, offline.

One display consequence: the approval dialog showed the stated reason only
for ``shell``. It now keys off the arguments, and hides only ``reason`` from
the raw argument list — the escalation booleans stay visible, because they
are the grant being approved and ``git`` now carries one too.

### Implementation notes (as built)

- The command is a **spec**: ``{:shell, command}`` or
  ``{:exec, file, args}``. The ``git`` tool uses the exec form, so its
  argument list is handed to git as argv and is **never re-parsed by a
  shell** — otherwise ``["log", "; touch marker"]`` would inject. Inside
  bwrap the exec form runs as
  ``sh -c 'ulimit …; exec "$@"' sh git <args>``; the shell exists only to
  apply the rlimits, and ``exec`` replaces it without re-parsing.
- ``Sandbox.confines?/0`` is the gate's question, distinct from "a
  sandbox is configured": ``None.confines?`` is false, and a confining
  implementation that is ``available?/0 == false`` also yields false.
  **ADR 030 changed the consequence**: a session refuses to start when
  this is false, so the gate's confinement fallback is unconditional in
  practice (shell/git allow-by-default; only escalations ask).
  **Superseded by ADR 046**: ``confines?/0`` is deleted; availability is
  the only question left.
- The port loop (spawn, deadline, kill, truncate) lives once in
  ``Core.Exec``, the single ``Sandbox.wrap`` call site shared by ``Shell``
  and ``Git``.

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
  STIG-compliant host it is not permitted — **ADR 030 supersedes the
  fallback**: those hosts cannot run the agent at all (no confining
  sandbox, no session), which is the accepted answer for a tool whose
  model is "confine or refuse".
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
6. **Script git write** — explicit per-invocation ``change_vcs``
   escalation; default stays read-only-``.git``.
7. **Relation to ADR 010** — ADR 015 **supersedes** decision 5.

Implementation order
--------------------

The first code step was intentionally trivial and behaviour-neutral: the
``Core.Sandbox`` behaviour with ``Sandbox.None`` only, wired at the Shell
call site, so the full test suite stayed green before any bwrap code
existed. Then ``Sandbox.Bwrap`` with the functional probe, then the
``rw``/``ro``/``hide`` mount schema, then the dedicated ``git`` tool and
the ``change_vcs`` escalation.

**ADR 030 (2026-09-27) finished the model**: ``Sandbox.None`` is now the
test seam rather than a runtime path, the native file tools run as
confined processes under the same profile, and session start requires
confinement. See ``030-one-boundary.rst``. (``Sandbox.None`` is itself
deleted by **ADR 046**; the original step remains here for the record.)

**Amended 2026-10-18 (the hidden path speaks, review N74).** The table's
``hide`` rows were both wrong when read against the code, and the code
was wrong in a second way. ``hide = [files]`` had drifted to
``--dev-bind /dev/null`` (the ``nodev`` of an unprivileged user namespace
makes a read-only-bound *device* unreadable, so the device was given
device access instead), and both images shared a real defect: from
inside, a hidden directory listed as empty, a hidden file read as the
empty string with a zero exit — **indistinguishable from absence**. The
finding that prompted this was ``AGENTS.md``'s "Deeper files" pointer
sending the agent to a directory a ``hide`` entry had emptied: the
sandbox hid the path and never said so, so the agent concluded the
document was stale rather than that its world was smaller than it looks.

``hide`` now binds the shipped notice
(``priv/coding-agent/sandbox/README.txt``) **read-only** over the path —
as a directory for a directory, as a file for a file. One flag
(``--ro-bind``), one asset, both kinds: the path exists, names itself as
hidden, refuses writes with ``EROFS``, and reads of anything else under
it fail exactly as if absent. The ``nodev`` workaround disappears with
the device.

Two consequences, both deliberate:

- **Descendant entries are pruned** (``Sandbox.Mounts.resolve/1``, by
  path component so ``/a/bc`` is not below ``/a``). They were pointless
  before — one mount hides the subtree — and are impossible now: bwrap
  cannot create a mount point inside a read-only bind
  (``Can't create file /a/b: Read-only file system``). A ``hide`` entry
  under an ``rw``/``ro`` bind was already broken before this change and
  stays broken; it is now at least reported as a startup failure rather
  than silently mounting nothing.
- **Search sees the notice.** ``fd``/``rg`` now return the notice file
  under a hidden directory, where an empty tmpfs returned nothing. That
  is the point of the change — the harness does not pretend the path
  does not exist — but it is a visible behaviour change for anything
  that counts matches.

Measured 2026-10-18 under bwrap 0.12.0, because the interesting
consequence is counter-intuitive: ``rm``/``mv`` of a hidden file fail
with **EBUSY** (``Device or resource busy``), not with the ``EROFS`` a
read-only *file* reports, because the path is a mount point of the
scope bind and an unprivileged namespace cannot detach it. ``tee`` on
the same path does report ``EROFS``. The error is honest — the path is
still there — and the host file is untouched in every case.

Amendment 2026-10-22: the grant is called ``change_vcs``, and EROFS learns to
say why
----------------------------------------------------------------------------

Two corrections from one dogfooding session — a ``shell`` call that tried
to commit in a linked worktree.

**The keyword is renamed ``git_write`` → ``change_vcs``.** The old name was
not wrong about the mechanism (the grant is what re-binds the git
metadatas read-write) but it named a PATH, and the path is wrong as soon
as the scope root is not the repository root. In a linked worktree the
read-only binds are ``<main>/.git/worktrees/<name>`` and its commondir,
both OUTSIDE the scope; in a plain checkout they are ``<scope>/.git``. A
reader who takes ``change_vcs`` literally looks for the thing inside the
scope and finds a gitfile. ``change_vcs`` names the effect (the
repository's version control state — index, objects, refs), matches the
wording the sandbox profile already used, and a second VCS widens the same
grant instead of adding a synonym. Renamed in the schema, ``Escalation``,
the profile key, the gate and every current sentence of this ADR — the
keyword is something a caller TYPES, so a stale spelling in prose is an
instruction that no longer works, which is a different case from the
``blacklisted?``→``redirect`` rename that kept its historical text.
``Sandbox.Bwrap.git_args/2`` keeps its name: it emits git binds, and it is
private.

**"it cannot write .git" was false, and the honest sentence is about
symptoms.** The ``shell`` description said the command ``cannot write
.git``. In this very worktree the failing path was
``<main>/.git/worktrees/<name>/index.lock`` — not the ``.git`` entry in
the scope, which is a FILE pointing there — so the sentence described
something the caller could not see and implied a capability
(write another checkout's repository metadata) that never existed. It now
names what will be observed instead: a git command that changes the
repository fails with ``index.lock: Read-only file system`` unless the
call grants ``change_vcs``. That is a symptom the model can match against
its own output, which the previous sentence was not.

**The fourth P5 path: act on the failure, not on the spelling.** Widening
the redirect table to ``cd … && git …`` was considered and rejected
(owner ruling): it is a war of spelling against spellers — first ``cd x &&
``, then ``bash -c``, then a script that is written to a file first — and
the table's blindness is what makes it advice rather than a wall
(2026-10-13 (b)). Parsing git's error messages was rejected too, and for a
sharper reason: enumerating "all the ways a git command can fail on a
read-only ``.git``" is unbounded, and any list would be wrong within a
version.

So ``Shell`` appends a note to a shell result whose output contains
``Read-only file system`` — ONE kernel string, not a program's prose — and
the note states facts about the profile the call ran with, which the
harness knows exactly:

* the trigger is the OUTPUT, not the exit status. ``git commit … | tail
  -1`` exits 0 with its first command failed; 21 of the 45 EROFS rows in
  the store are that shape, so a status-gated note would miss exactly the
  failures it exists for. Appending to a successful result is
  deliberate — it does not suppress or rewrite the output (ADR 030).
* ``root_ro`` wins the explanation when set: it is a policy, no flag lifts
  it (the narrower grant wins), so the note says "a policy, not a missing
  flag" rather than sending the agent after ``change_vcs``.
* otherwise the note names the missing ``change_vcs`` grant AND the
  ``git`` tool that always has it, phrased conditionally — "if that is
  what failed". The profile knows which grant was absent; it does not know
  which path the program tried to write, and a note that asserted the
  cause would be the same kind of lie as the sentence this amendment
  removes.
* a failure with no EROFS in it gets no note. The note is bounded: no
  heuristic on command text, no diagnosis of anything but the profile.

