:orphan:

Permission gate and policy file format
======================================

.. adr::
   :id: 010
   :status: Proposed
   :date: 2026-08-30
   :tags: security, permissions, tools

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