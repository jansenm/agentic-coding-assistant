:orphan:

Agent specialization: specialist/repository matrix
==================================================

.. adr::
   :id: 007
   :status: Proposed
   :date: 2026-08-29
   :tags: agents, multi-agent, permissions, roadmap

Context
-------

Work happens on large, multi-repository projects (a Java workspace with
12+ repositories). The owner's working style is to define several agents
with concrete responsibilities rather than one general-purpose agent,
and to run agents across all repositories without overloading a single
context window.

The required model is a **specialist/repository matrix**:

- *Vertical agents* — one per repository per specialty ("maven
  build-setup for repo A", "Java code for repo A"). Context is scoped to
  one repository.
- *Horizontal specialists* — one specialty across all repositories
  ("the Jenkinsfile specialist works on all repos at once"). Context is
  scoped to the specialty's file patterns across repos, never to whole
  repositories.

Future capabilities this interacts with: advanced tools, an agent
permission system, multi-agent roles (plan/execute/analyze), skills,
ACP/MCP integration.

Analysis
--------

The matrix is a context-arithmetic solution: specialist knowledge is
cheap (idioms, conventions), repository knowledge is expensive (file
trees, history). The matrix never mixes them into one window. Three
context scoping rules follow:

1. Vertical agents see one repository.
2. Horizontal specialists see their file pattern across repositories
   plus their expertise — not the repositories.
3. An orchestrator (plan/execute roles) sees only the plan and the
   summaries agents return — subagents work in isolated contexts and
   report results, not transcripts.

In this project's architecture (ADR 003) an agent is a supervised
process running the standard loop, parameterized by data:
``{name, system_prompt, tools, permissions, scope}``. The matrix is a
configuration of that data, not new code.

The permission system falls out of the matrix as an access-control
table: ``(agent role) x repositories x tool x path-pattern``. Example:
the Jenkinsfile specialist may write ``Jenkinsfile*`` in all 12
repositories but may not run ``mvn``; a maven agent may write only
inside its own repository and may run ``mvn``. The composition rule
with the policy layers is decided in :doc:`010-permission-gate`:
**the most restrictive layer wins** — agent templates restrict but
never grant, and each repository's policy governs every agent
(including horizontal specialists) that touches it.

Open question — *atomicity for horizontal changes*: one consistent
Jenkinsfile change across 12 repositories is 12 commits. Whether those
become 12 PRs, one orchestration-managed changeset with coordinated
rollback, or follow another protocol is undecided and must be designed
before multi-repo writes ship.

Decision
--------

Adopt the **specialist/repository matrix** as the target model for
multi-agent operation (proposed; implementation follows the core
single-agent loop). Constraints binding earlier decisions:

- Agent definitions are **data**, not code, from the start.
- The tool subsystem (ADR 003 consequences) is **scope-aware** from its
  first version, even if the only initial scope is "one working
  directory".
- Orchestration, horizontal specialists and cross-repo atomicity are
  built **after** the single-agent loop is functional; the matrix never
  changes the loop itself — it only adds processes and scoping.

Consequences
------------

- Trusting one agent does not mean trusting all: each agent type carries
  its own permission row, reviewed independently.
- The BEAM model fits: parallelism across 12 repositories is
  concurrency, not architecture; concurrency limits become a resource
  control, not a redesign.
- The matrix keep contexts small by construction, complementing (not
  replacing) compaction (see :doc:`../explanation/memory`).