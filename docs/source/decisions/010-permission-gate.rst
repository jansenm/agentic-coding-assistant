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
   ``agent-permissions.toml`` (with a session restart — policy pins at
   start). Demo: ``demo/acceptance_2b.exs``.

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
  the two layers stay separable (naming: the file is called
  ``agent-permissions.toml`` — not ``.agents.toml`` — precisely to
  avoid confusion with AGENTS.md).

Decision
--------

**1. Policy format — TOML**, loaded with the already-present ``toml``
library (zero new dependencies). One file:
``agent-permissions.toml`` at the project root (name decided here;
rename cost later is one path constant).

Schema (v1, deliberately minimal):

.. code-block:: toml

   # agent-permissions.toml
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
2. project file (``agent-permissions.toml``),
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
   followed) and must stay inside the session scope
   (``Containment.check_scope!/2``); the walk discipline of the
   read-only tools (the path-hardening lessons). The tool cannot
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