.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

Permission gate and policy file format
======================================

.. adr::
   :id: 010
   :status: Accepted
   :date: 2026-08-30
   :tags: security, permissions, tools

.. note::
   Accepted 2026-08-30 after the slice-2b acceptance demo: the same
   ``write_file`` call took allow and ask paths driven only by editing
   the project policy file (with a session restart — policy pins at
   start). Demo: ``demo/acceptance_2b.exs``.

   **Renamed by ADR 014** (2026-09-13): the file is now
   ``.coding-agent/permissions.toml``. The pre-ADR-014 name
   ``agent-permissions.toml`` at the scope root is **not read** — the
   software is unreleased and carries no legacy (AGENTS.md).

   **Amended by ADR 030** (2026-09-27): the boundary for file reach
   moved from the BEAM path check (``Containment.check_scope!/2`` and
   the walk discipline) to the process sandbox — the file tools now run
   as confined processes. The gate's policy model, decision API and
   ``:allow | :ask | :deny`` vocabulary are unchanged; the read-only and
   write-only "structural fence" described below is now enforced by the
   sandbox profile instead of a path predicate.

Context
-------

Slice 2b (roadmap) introduces the first state-changing tool
(``write_file``). Per ADR 003 and the roadmap, no state-changing tool
may exist before a permission gate governs it. This ADR decides the
gate's design: policy formats, load order, defaults, decision API, and
the shell-semantics sketch.

Requirements recap (from earlier decisions):

- The permission table is *data*, not code (ADR 007) — editable without
  recompiling, reviewable in diffs.
- A cloned project must never be able to elevate its own permissions
  (ADR 002's supply-chain threat model, applied to policy files).
- Instructions (AGENTS.md) steer behavior *within* policy limits and
  can never change them; policy lives in its own structured format so
  the two layers stay separable (naming: the file was called
  ``agent-permissions.toml`` — not ``.agents.toml`` — precisely to
  avoid confusion with AGENTS.md; renamed to
  ``.coding-agent/permissions.toml`` by ADR 014).

Decision
--------

**1. Policy format — TOML**, loaded with the already-present ``toml``
library (zero new dependencies). One file at the project root — named
``agent-permissions.toml`` here, since renamed to
``.coding-agent/permissions.toml`` (ADR 014).

Schema (v1, deliberately minimal):

.. code-block:: toml

   # .coding-agent/permissions.toml
   [permissions.write_file]
   "docs/**"        = "allow"   # auto-approve
   "src/bank/**"    = "deny"    # never even ask
   # no match       -> ask      (default for state-changing tools)

   [permissions.shell]
   "*"              = "ask"     # every shell call pauses

- The table keys are ``(tool-name, path-pattern)``; the values are the
  atoms ``allow | ask | deny``. ``deny`` beats ``allow`` (safest-match
  wins, then most-specific wins; no match = default policy).
- Tool *enablement* rides in the same file
  (``[tools] enabled = [...]``); per-specialty agent definitions ride
  in this format later (ADR 007) — it must stay expressible, not
  express it now.

**2. Load order and the non-elevation rule** — policy layers merge with
*the more restrictive decision winning*:

1. built-in defaults (see below),
2. project file (``.coding-agent/permissions.toml``),
3. user-level overrides (``~/.config/coding-agent/permissions.toml``,
   optional, phase 4).

A project file may only make decisions *more* restrictive than the
user layer, never less. Concretely: project entries can turn
``allow`` into ``ask`` or ``deny``, and ``ask`` into ``deny``; never
the reverse. A warning is emitted when a project entry attempts
elevation and it is ignored.

**3. Default policies** (when no entry matches; also the schema
defaults):

========== =========== ==================================
Tool class Decision    Rationale
========== =========== ==================================
read-only  ``allow``   reading leaks nothing by itself
write      ``ask``     every state change is confirmed once
shell      ``ask``     each command confirms
========== =========== ==================================

A tool *unknown* to the policy defaults to its class; an unknown
*tool name* is never executed regardless of policy (the loop already
answers "unknown tool").

**4. HITL decision API — UI-agnostic, three verbs:**

.. code-block:: elixir

   # pause: session status :interrupted carries the pending calls
   # (machinery exists since phase 1); the driver decides:
   :approve                    # execute with original arguments
   {:edit, new_args}           # execute with modified arguments
   :reject                     # skip execution, tell the model it was rejected

The API deliberately matches the three verbs the LLM can make sense of.
Batch semantics (a parallel tool-call batch with some approved, some
rejected) are decided per-call: the *session* collects decisions for
every pending call and resumes only when every call has a decision.

5. **Shell command semantics — always-ask in v1.** A command allow-list
   (``"mix test"`` → allow) is attractive but is a known footgun
   (quoting, chaining via ``&&``, subshells). v1 therefore has no
   shell allow-list; every shell call is ``ask``. A pattern-allowlist
   for shell may come later as its own ADR with a tested parser — not
   a regex string-match we would pretend is meaningful.

   **Superseded by ADR 015** (2026-09-17). The allow-list insight
   stands; the "every shell call is ``ask``" consequence does not.
   ADR 015 bounds the process with OS-level confinement instead, so
   ``shell`` is allow-by-default inside the profile and only genuine
   escalations (network, ``.git`` write) remain ``:ask``. Retained here
   for the record.

6. **Shell read-only mode** (2026-09-21). A policy or agent definition
   may write ``shell = "read_only"``: the gate resolves it to ``:allow``
   AND the sandbox binds the scope root read-only (``root_ro``). This is
   not a fourth decision — decisions answer "prompt or not", confinement
   answers "what may the process reach" (ADR 015) — but it *is* part of
   the permission table the author writes, because it is a narrowing of
   the shell capability. It merges most-restrictively (``:ro`` wins) and
   is shell-only. ``root_ro`` is a grant the sandbox either honours or
   refuses; **superseded by ADR 046**, which deleted the non-confining
   ``Sandbox.None`` that used to refuse it (``:root_ro_unavailable``). See
   ADR 017 for the ``plan`` use.

**6. Approval surface in 2b is a stub.** ``mix agent`` prints the
pending call and reads a line (``y`` / ``e`` / ``n``); edit prompts for
new arguments. The real TUI approval flow is phase 4. The contract
being pinned here: the decision API is symmetric for every driver —
the session never knows whether a human, a TUI widget, or a test made
the call.

**7. Loading fails closed.** A malformed, unparsable or schema-violating
policy file aborts session start with a clear error — it never silently
falls back to defaults (defaults are what an attacker achieves by
deleting or corrupting the file). Unknown *sections/keys* are ignored
with a warning (forward compatibility); unknown *decision values*
(anything not ``allow | ask | deny``) fail the load.

Interaction with the agent matrix (ADR 007)
-------------------------------------------

The matrix (who works where) and the permission system (what may be
touched by whom) compose on the tuple ``(agent role, tool,
resolved-repo)`` with one rule:

**The most restrictive layer always wins.**

``effective(role, tool, path)`` = most restrictive of:

1. built-in class default (write → ``ask``, shell → ``ask``),
2. user-level file (the human's own global limits),
3. the *repo-side* file of the repository the resolved path belongs to,
4. the effective permission set of the running agent definition: its
   own ``permission`` frontmatter (agents-standard format, see below)
   plus its entries in ``[agents.<role>.permissions]`` —
   which may only restrict, never grant.

Properties:

- **Templates restrict, never grant.** A Jenkinsfile specialist's
  definition may narrow what it can do; its write authority comes only
  from the repo/user layers. Same non-elevation invariant as rule 2,
  extended to one more layer.
- **A repository governs every agent that touches it.** Repo B's
  ``deny ci/**`` applies to a horizontal specialist dispatched across
  twelve repos — an orchestrator's choice never overrides a repository
  owner. This is the matrix-specific form of the cloned-repo rule.
- **Convention frontmatter is one of these layers.** The agents
  standard's optional ``permission`` section in agent/skill definition
  files (used by opencode et al.) is honored as a
  restrictive-only layer in the same merge. A definition declaring
  ``"**/pom.xml": allow`` does not thereby write pom files in a repo
  whose layer says ``ask`` — the intersection decides. This keeps
  ``.agents/...`` definition files tool-portable while enforcement
  authority stays with user and repo layers.

Format impact, additive only:

- Entries may live under ``[permissions.*]`` (every role) or
  ``[agents.<role>.permissions]`` (one role); same syntax, same merge.
  The lookup is the same function in both cases — in 2b every session
  runs the implicit role ``default``, so the function is implemented
  now with a single known argument and nothing is deferred.
- Agent definition files in the agents-standard frontmatter format
  (``.agents/agents/*.md`` style, opencode-compatible) are consumed
  including their ``permission`` section, mapped onto the same
  decision vocabulary (``allow | ask | deny``) and fed into layer 4.
  The pattern-matching dialect to support there (opencode uses
  last-match-wins globs) is pinned when the loader is implemented in
  slice 2b / phase 5 — the merge rule does not depend on the dialect.
- Multi-repo workspaces (phase 5) turn ``scope_root`` into a list of
  roots; path→repo resolution is the only new mechanic. In 2b,
  single-root, "the repo file" *is* the workspace file.

Consequences
------------

- ``write_file`` exists only after the gate exists; the gate is
  testable without it (2a tools remain gate-exempt by policy class).
- Policy changes take effect on *next session start* (no live reload in
  2b — an explicitly deferred nicety).
- The gate checkpoint is one function in the session loop
  (``check_permissions(state, calls)``); unit-testable without a UI.
- Shell remains unimplemented until 2b's gate is demonstrated; 2c then
  builds on the ADR 010 semantics without redesign.
- A future ``--yolo``-style flag bypassing the gate is *not* provided
  by the core; if ever built, it is a driver-side concern that must
  still pass through the gate API (auditable, logged).
- The role dimension exists in the lookup function from day one
  (role ``default`` in 2b), so the matrix phase adds data and
  resolution, not a permission redesign.

Amendment 2026-09-15: edit and write_file join the allow class
--------------------------------------------------------------

**Status: Accepted (amendment to the accepted ADR 010).**

Live sessions with the shipped defaults paused on every ``edit`` and
``write_file`` — the annoyance was prompt noise, not safety. Both
tools are fenced *structurally* (the check decides) in the same sense
as the read-only tools; the per-call human pause bought nothing the
working tree does not already give. The fence is containment plus
VCS reviewability, enforced in the tools themselves, not by the gate:

1. **Contained** — every path is resolved physically (symlinks
   followed) and must stay inside the session scope; since ADR 030 this
   is enforced by the confined file tools (``Tools.FileExec``) rather
   than a BEAM predicate. The tool cannot
   touch anything outside the workspace, no matter what the model
   asks for.
2. **Reviewable** — every landed change sits in the VCS working tree
   as a diff. The evidence the approval prompt offered ("here is
   what I am about to change") is the same diff the user reviews in
   git — seen earlier, in context, and revertible. The prompt added
   a keystroke, not a check.

``edit`` additionally fails closed on the match (``old_string`` must
occur *exactly once*; stale and ambiguous matches refuse — it cannot
guess, clobber or spray). ``write_file`` has no such uniqueness gate,
but its blast radius is one file in a VCS-managed tree: the
pre-change content is recoverable from git even when the write lands
unwanted, and the diff surfaces it. Where the workspace is *not*
under version control the user layer should keep both tools at
``ask``:

.. code-block:: toml

   # ~/.config/coding-agent/permissions.toml
   [permissions.edit]
   "*" = "ask"

   [permissions.write_file]
   "*" = "ask"

``shell`` obviously stays :ask (no containment — fenced socially, see
decision 5). ``webfetch`` stays :ask (foreign content ingress). The
class default list in ``CodingAgent.Core.Permissions`` is the single
point of truth.

The lookup semantics are unchanged — the amendment changes only the
built-in class defaults for the tool names ``edit`` and
``write_file``; per-path entries (``[permissions.edit] "src/**" =
"ask"``) still apply above the class default,
most-restrictive-wins across layers is untouched, and a repo or user
file can turn either tool back into ask/deny per path.

Acceptance: ``test/coding_agent/core/permissions_test.exs`` locks the
class defaults, the gate-integration tests in ``edit_test.exs`` and
``write_file``'s tests prove contained calls run without a pause
under the bare defaults, and the same tests prove repo-side
``[permissions.*]`` entries still interrupt.

Amendment 2026-09-15 (2): shell command blacklist — steering, not containment
-----------------------------------------------------------------------------

**Status: Accepted (second amendment to the accepted ADR 010).**

Live sessions with the allow-class defaults showed where the keystroke
cost actually lived: not in the write tools (amendment 1 solved those)
but in ``shell`` calls that duplicate a native tool — most visibly
``grep``-style searches, which the model reaches for because shell is
its one universal tool. The 2026-09-15 roadmap note sketched a
protected-*path* ask-class; the live evidence points the opposite way
(the user explicitly declined an allow-list): the pain is not that
dangerous shell runs too freely, but that the model repeats work the
harness already has tools for — and every such call costs a ``y`` for
nothing. y-fatigue is the enemy of the gate: a user trained to press
``y`` after the first ten prompts is a user who will not read the
eleventh, which *is* the safety loss.

**Decision: a redirect table, checked before the policy lookup.** Not
"these commands are safe", but "this shell spelling duplicates a native
tool — use the tool". A shell call whose leading program is in the table
is answered with a one-line hint as its tool result, in the same round:

.. code-block:: elixir

   # lib/coding_agent/core/tools/shell.ex — @redirect (v1)
   "grep" => "please use the grep tool instead of shell grep ..."
   "rg" / "ag" / "ack" / "sg" => "please use the grep tool ..."

The verdict is a *hint*, not a result: ``Shell.redirect/1`` returns
``{:hint, message}`` when there is something to steer the model with and
``:ok`` when there is not. ``:ok`` is **not** "this command is safe" —
nothing in the table decides that; the sandbox profile does. It means
only "nothing to redirect you to", which is why the two returns carry
their own tag rather than an ``{:ok, message}`` next to an ``:error``
that reads like "the check passed". (The 2026-09-15 text called the
function ``Shell.blacklisted?/1`` and the bucket ``:blacklisted``; the
rename is a later amendment — see the note at the end of this section.)

The check is deliberately **shallow**: the first command word only —
basename of an absolute path (``/usr/bin/grep`` is caught), after
env-var assignments (``FOO=1 grep …``) and shelling-out wrappers
(``env`` / ``command`` / ``nohup``). Pipes do not widen the check
(``echo hi | grep hi`` runs), and evader spellings pass (``bash -c``,
``awk``, ``find -exec``).

**Pipes are a live question, deferred on purpose.** A pipe is the one
plausibly *legitimate* shell-grep shape (``cat x | grep y`` is rare —
``grep y x`` does it — but ``docker logs c | grep err`` is real: the
left side produces the stream, grep merely filters). If live sessions
show piped greps costing real keystrokes, the next step is a second
segment in the verdict — after a ``|``, look at the next pipeline
stage's leading word the same way — denying only the *standalone*
grep and leaving piped ones to the gate's ``:ask`` (where the human
sees the whole command). Deliberately NOT done now: no live evidence
yet of the shape, and each widening deserves its own evidence.

Honesty about what this is and is not:

- **Not containment.** A committed agent bypasses it in five spellings;
  a malicious agent was never stoppable by a word list anyway (the
  ADR 010 threat model already says so: the human sees the full command
  at the gate on every non-denied call — that remains the real fence).
- **It is prompt hygiene with a measurable gate-economics payoff.**
  The native ``grep`` tool is allow-by-policy, so a denied shell grep
  converts "ask + wrong-tool output" into "deny + redirect" — the model
  re-emits the call against the native tool and the user's net
  keystroke count for the search drops to zero.
- **The tool callback stays a pure executor.** The verdict lives in
  ``Shell.redirect/1`` (public, unit-testable), the session's gate
  checkpoint consults it before the policy lookup and answers redirected
  calls with tool-result messages directly. A direct
  ``ReqLLM.Tool.execute`` bypasses the check — the gate is the policy
  point (same discipline as the timeout soft cap).

``sed -n`` (print-only) → ``read_file``/``edit``, ``cat`` →
``read_file``, ``ls`` → ``list_dir`` are deliberate one-line follow-ups
(same table, new entries) — not done now; each new word needs its
collision check (``cat`` the pager-alias, ``ls`` the Lisp interpreter)
and its own live evidence.

Consequences: every redirected call is a log line
(``gate: shell command redirected (native tool)``); the class-default
allow-list in ``Permissions`` is untouched (this check is shell-only
and tool-argument-shaped, not path-shaped); the roadmap's
protected-path sketch (``.git/**``, ``AGENTS.md``) remains the open
half of the y-fatigue story — paths where a write is invisible to the
review argument.

Acceptance: ``test/coding_agent/core/shell_test.exs`` — the redirect
unit table (family members, basenames, wrappers, degenerate inputs,
deliberate misses in both directions) plus gate-integration tests
proving a redirected call produces NO interruption, the hint
reaches the model as its tool result, and non-redirected shell calls
still pause.

Amendment 2026-10-13: the redirect verdict is a hint, not a blacklist
---------------------------------------------------------------------

The 2026-09-15 amendment above shipped the mechanism under a name that
said the opposite of what it does: ``Shell.blacklisted?/1`` returning
``{:ok, message} | :error``. Three problems, all naming:

- **``:error`` did not mean "unsafe".** It covered "not a native-tool
  duplicate", "a deliberately uncaught evader spelling" and "degenerate
  input" alike, and the ``:ok``/``:error`` shape is the one for *did the
  operation succeed* — so every reader parsed ``:ok`` as "the check
  passed", which slides into "the command is safe". It decided neither:
  the sandbox profile decides safety, this table decides nothing at all.
- **The caller matched an absence.** The gate wrote
  ``match?({:ok, _}, Shell.blacklisted?(args))``; matching on a missing
  result is how the misreading got typed in.
- **``blacklist`` named the opposite of the mechanism.** Nothing is
  blacklisted here — the call is answered with a line telling the model
  which tool to use instead, and an explicit policy entry plus the
  sandbox still own the actual decision.

Renamed with this amendment: ``Shell.blacklisted?/1`` → ``Shell.redirect/1``
returning ``:ok | {:hint, message}``; the gate's bucket ``:blacklisted``
→ ``:redirected``; ``Gate.blacklist_result/1`` → ``Gate.redirect_result/1``;
the log line ``gate: shell command denied (blacklist)`` →
``gate: shell command redirected (native tool)``. Same table, same
first-word check, same no-keystroke answer — with the one addition below.

Amendment 2026-10-13 (b): the hint is advice, never a wall
----------------------------------------------------------

The 2026-09-15 amendment's own honesty note says the check is
first-word-only and that ``bash -c`` walks around it. That asymmetry is
harmless while the hint is a *convenience*, but it inverts the outcome the
moment a row covers a command the agent may legitimately want to run **as
written** — ``git add`` in a release script being the live case::

   git add -A                       → first word `git` → hinted, never runs
   bash -c 'git add -A && mix test' → first word `bash` → reaches the gate

So the honest spelling would be steered away and the wrapped one would
reach the human and run. The row must therefore be escapable through the
mechanism the caller already has: **state an escalation** (``change_vcs:
true`` / ``network: true``, each with its ``reason``) and the call is left
alone and goes to the gate like any other escalated call. ``Shell.redirect/1``
returns ``:ok`` for it, so the hint is advice and can always be walked,
while the escalation still costs a keystroke and a stated reason.

Consequence, stated plainly: **a reasonless escalation is treated as no
escalation at all** — the call gets the hint, the escalation is not
granted, and the command fails against the mount instead of running wide.
A stated escalation is what the human answers; a bare ``true`` is not
answerable, so it does not count (the same shape as ``:no_reason`` at the
gate).

The ``git`` row itself: shell ``git`` duplicates the dedicated tool, which
is allow-by-default and may write ``.git``. The hint names both the tool
and the escape (``change_vcs: true`` with a reason, on a script that
**changes** the repository) — which is also where P5's "escalations are
only discoverable by failing" is answered: the message tells the model the
way out instead of leaving it to deduce one from EROFS.

Not renamed: ``@redirect`` (already correct), and the historical text
above keeps the old names — it records what was decided then, and this
amendment records the correction, rather than pretending the first
amendment said something it did not.

Amendment 2026-10-28: the table shrinks to the one shape it wins
-----------------------------------------------------------------

The redirect table is **gone**; what remains is one rule and one hint: a
**plain** grep-family search is answered with ``@grep_hint``, and nothing
else is redirected at all. ``Shell.redirect/1`` keeps its shape
(``:ok | {:hint, message}``) and keeps the escalation escape; the seven
rows, the ``cd … &&`` prefix handling and the timeout row are deleted.

**What the table cost.** Counted against this repository's own session
store on 2026-10-28 — 8 sessions, 519 display rows, 161 ``shell`` calls:
the table fired **twice**, and both firings were on a *composed* command
(``grep … | head``, ``grep … $(…)``) where shell was the **right** call,
because the derivation is what keeps the result small. Two false
positives, zero true positives, and 159 calls on which it did nothing.
Replaying the same 161 commands against a matcher that stripped a
``cd <path> &&`` prefix — the shape the 2026-10-25 ruling asked for —
took the firings from **1 to 79** of 161: 78 of those calls are
``cd ~/Projects/… && <program>`` because the caller names its directory
that way, so the prefix strip is a false-positive amplifier, not a fix.
It was implemented, measured, and removed.

**Why exactly one shape is left.** A hint is only worth a round if the
native tool is strictly better *for that call*. For a plain search it is:
``grep`` caps the list (200 results, 500 chars per line, 1 MiB per file),
**names** the files a walk skipped, spills the full list to a file, and
reports "no matches" as a sentence instead of exit 1 — and it is
allow-by-policy, so it costs no keystroke. A composed command gets none of
that: the tool has no pipeline, so ``grep -rn foo lib | head -40`` is
already the cheaper answer.

**Why ``git`` left.** Two reasons, both measured rather than argued. The
row never fired on a git call in that corpus (all 33 git-through-shell
calls were composed, i.e. ``cd … && git …``). And where a git *write*
actually needs the grant, the failure already explains itself: through
real ``bwrap`` with ``change_vcs: false``, ``git commit`` prints
``fatal: Unable to create '<root>/.git/index.lock': Read-only file
system`` and ``Shell.note/2`` appends the cause, naming the git tool and
``change_vcs: true`` with a reason. Same one round to recovery as a hint,
and a note cannot fire on a call that would have worked. ``git log``,
``git diff`` and ``git status`` through shell are byte-identical to the
tool anyway, so there was nothing to win. The timeout row was a parameter
both tools already document.

**The escape is unchanged** (2026-10-13 (b), still load-bearing): a call
that states an escalation — ``network: true`` / ``change_vcs: true`` plus
a ``reason`` — is asking to run this command as written and goes to the
gate like any other escalated call. The 2026-10-25 ``cd … &&`` widening
is **withdrawn**; ADR 015's rejection of it stands on better evidence now.

Acceptance: ``test/coding_agent/core/shell_test.exs`` — a plain
grep-family search (family members, absolute paths, ``FOO=1`` prefixes)
hints; every composed shape (``|``, ``&&``, ``;``, ``>``, ``2>&1``,
``$(…)``, a backtick, a ``cd … &&`` prefix) and every non-grep leading
program (``git``, ``timeout``) runs; degenerate inputs stay ``:ok``; the
gate-integration tests prove no interruption, the hint as the tool
result, and the log line.