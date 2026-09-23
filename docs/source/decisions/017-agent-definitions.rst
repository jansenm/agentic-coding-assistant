:orphan:

Agent definitions: user-authored presets, primary and subagent
==============================================================

.. adr::
   :id: 017
   :status: Accepted
   :date: 2026-09-17
   :tags: agents, multi-agent, permissions, configuration

.. note::
   Accepted 2026-09-17. Fills in the agent-definition layer ADR 010
   already reserved (its layer 4) and takes the first concrete step of
   ADR 007's matrix. v1 scope is deliberately small: definitions +
   the two primary agents (``build``, ``plan``) + switching. The
   ``task``/subagent seam follows in the next slice, on this basis.

Context
-------

ADR 007 named the target model (a specialist/repository matrix) and
ADR 003 defined an agent as *data* run by the standard loop
(``{name, system_prompt, tools, permissions, scope}``). Two things were
still unspecified: **what a user-written agent looks like on disk**, and
**how an agent's authority is derived** rather than chosen ad hoc.

Two independent axes are at play, and conflating them was the earlier
mistake:

1. **Definition — who am I?** A preset: prompt, tools, permissions,
   model, scope. Authored by the end user ("documentation writer",
   "code reviewer"). This is ADR 007's territory.
2. **Relationship — how was I started?** ``primary`` (the human talks to
   it directly) versus ``subagent`` (another agent starts it via a tool;
   ephemeral; it returns a summary, not a transcript). This is the
   ``task`` seam.

They are orthogonal: a reviewer can be started by a human *or* delegated
to by an orchestrator, and both use the same definition. The two
reference implementations this project follows — opencode and Claude
Code — model exactly this (``mode: primary | subagent | all``), and
both converged on the same on-disk standard.

The standard
------------

There *is* a de-facto standard, and opencode and Claude Code agree on it
almost field for field. We adopt it rather than invent one:

- **Markdown with YAML frontmatter.** The file name is the agent name;
  the Markdown body is the system prompt. Long prompts are prose, not a
  quoted TOML string — the decisive ergonomic argument.
- **Locations**, layered weakest to strongest (ADR 014's pattern):
  built-in (shipped) < user ``~/.config/coding-agent/agents/*.md`` <
  project ``<scope_root>/.coding-agent/agents/*.md``.
- **Required fields:** ``description`` (the delegation hint the model
  reads) and ``name`` (Claude Code also requires ``name``; we derive the
  name from the file name when absent and warn on mismatches).
- **Optional fields we honour:** ``mode`` (``primary``/``subagent``/
  ``all``), ``model``, ``tools`` (allow-list) and ``disallowedTools``
  (deny-list), ``permission`` (glob → ``allow | ask | deny``),
  ``temperature``, ``maxTurns``, ``hidden``.

.. note::
   ``temperature`` was parsed but ignored until ADR 024 wired it into the
   request opts. ``maxTurns`` is wired by ADR 025 (Proposed) as the
   per-agent turn budget. ``hidden`` remains under review.

The ``permission`` section is the format ADR 010 layer 4 already
anticipated (opencode-compatible, restrictive-only).

Decision
--------

**Agent definitions are Markdown + YAML frontmatter files, discovered
like every other configuration layer, and an agent's authority is the
most-restrictive intersection of four layers — never a grant.**

### Authority derivation (the point of the whole exercise)

An agent's effective permissions are the most restrictive of:

1. the built-in class default (read-only tools allow, others ask),
2. the user layer (``~/.config/coding-agent/permissions.toml``),
3. the repo layer (``<scope_root>/.coding-agent/permissions.toml``),
4. the agent definition's own ``permission`` frontmatter.

This is ADR 010's existing merge with layer 4 finally populated. The
properties carry over unchanged:

- **Definitions restrict, never grant.** A ``plan`` agent that sets
  ``edit: deny`` cannot edit; a definition that sets
  ``"**/pom.xml": allow`` still prompts if the repo layer says ``ask``.
- **A repository governs every agent that touches it** (the cloned-repo
  rule): an agent definition checked into a repo cannot widen its own
  authority by declaring more permissions.

### Escalations are part of the definition, not a runtime question

An escalation (network access, ``git_write``) is a conversation with a
human: it needs a stated reason and a decision. A **subagent has no
human channel** — it runs inside the ``task`` call and reports a summary.

Therefore: **escalations are declared in the definition, reviewed when
the user writes it, and never requested at runtime by a subagent.** An
"network installer" subagent has ``network = true`` in its file because
the user chose that, not because it asked mid-run. A ``primary`` agent
*may* additionally escalate at runtime (it has the channel, via the
ADR 015 gate); a subagent may not. This keeps the approval dialog at a
single place and makes an agent's authority fully reviewable before it
ever runs.

### Built-in agents

Two, and only two, shipped as data:

- **``build``** (primary, default) — full tools; the current behaviour.
- **``plan``** (primary) — ``edit``/``write_file`` and ``shell``/``git``
  ``deny`` (or ``ask``; see open questions), so it analyses and proposes
  without changing anything.

``build`` and ``plan`` are the two the owner actually uses in opencode;
more are user files, not shipped code. Review/explore are *prompt
presets* a user can write against the same machinery, not built-ins —
they need no new code.

### Relationship axes and v1 limits

- ``primary`` agents are switchable in the TUI with **Tab**
  (additionally settable at launch, e.g. ``--agent plan``).
- ``subagent`` execution (the ``task`` tool) is defined here but
  implemented in a following slice. Constraints fixed now so the seam
  cannot drift: a subagent returns **only a summary** (ADR 007 rule 3),
  starts with an **isolated context**, and **may not start further
  subagents** (depth 1 — bounded fan-out and cost, and delegation stays
  with the orchestrator).

Consequences
------------

- A user adds a specialist by dropping a Markdown file in
  ``~/.config/coding-agent/agents/`` — no code, no rebuild (ADR 007).
- The permission story is one merge, already specified (ADR 010): the
  new work is a frontmatter loader, not new enforcement.
- The two axes stay independent, so the ``task`` slice adds processes
  and scoping (ADR 007) without touching the loop.
- Trusting one agent does not mean trusting all: each definition carries
  its own reviewable row.

Implementation decisions (2026-09-17)
-------------------------------------

1. **``plan`` denial strength:** ``deny`` **and a read-only shell**
   (revised 2026-09-21, see below). ``edit``, ``write_file`` and the
   ``git`` tool are removed from ``plan``'s tool set entirely. ``shell``
   is *kept* but marked read-only: the sandbox binds the scope root
   ``--ro-bind``, so ``plan`` can do archaeology (``git log``/``blame``/
   ``diff``, ``grep``, ``cat``) but cannot write the tree — builds that
   write in-tree fail. The original ``disallowedTools: … shell`` blocked
   the archaeology too, which made ``plan`` unable to investigate the
   repository it was asked to plan against.
2. **Frontmatter parse failures:** fail closed, but **aggregate** — the
   loader parses *every* definition file, collects all errors (file,
   line, reason), prints them as one numbered list, and then refuses to
   start. This deliberately differs from the policy loader (which aborts
   on the first error): agent files are numerous and user-edited, so
   fixing them one restart at a time is the unpleasant loop we avoid.
3. **Name authority:** the ``name`` field wins; the file name is the
   fallback when it is absent. Two definitions in the same layer
   resolving to the same name is an error, reported in the aggregated
   list (not a silent filesystem-order pick).
4. **YAML parser:** see :doc:`019-yaml-dependency` — ``yamerl`` directly,
   one dependency, with a hard size limit and the core schema.

### Read-only shell (``shell: read_only``, 2026-09-21)

Both reference tools keep a *read-only shell* in plan (opencode allows
read-only ``bash`` by default; Claude Code has a built-in read-only
command set). This project's earlier design removed ``shell`` wholesale,
which cost the archaeology. The replacement is a **capability qualifier**
on the shell key:

.. code-block:: yaml

   permission:
     shell: read_only     # allowed, but the scope root is bound read-only

It is deliberately **not** a fourth decision. ``allow | ask | deny``
answer *"prompt or not"* (the gate, ADR 010); read-only-ness is
**confinement** (what the process may reach, ADR 015). So the value
resolves to ``:allow`` for the gate plus a policy-level ``shell_mode``
that flows into the sandbox profile as ``root_ro: true``. The layers
merge like a decision: **``:ro`` wins**, a lower layer can never widen it
back to ``:rw``, and ``read_only`` on any tool other than ``shell`` is a
load error (only ``shell`` has a rw/ro root).

Two properties worth stating:

- **It closes a real bypass.** ``plan`` denied ``edit``/``write_file``
  but, given a writable ``shell``, could still ``echo > src/f.ex``. The
  read-only root makes the sandbox enforce what the policy only gestured
  at. Measured under bwrap: ``cat``/``git log``/``git diff``/``git
  status``/``git blame``/``grep`` succeed; ``touch``/``mkdir``/``rm``
  fail with *Read-only file system*.
- **It refuses rather than degrades.** ``Sandbox.None`` (macOS, Windows,
  no bwrap) cannot make a root read-only, so it returns
  ``{:error, :root_ro_unavailable}`` and the shell call fails with a
  message pointing at the read tools. Silently running read-write would
  reinstate the bypass on exactly the hosts where the gate is the only
  boundary.

The cost accepted: **in-tree builds fail for ``plan``** (``mix compile``,
``cargo build``, ``mvn``). The owner's call is to try this before
conceding, since most planning is reading and reasoning; a planner that
truly needs to build is a named future agent, not ``plan``.

### Where a definition's prompt goes (a fork worth naming)

This ADR composes the definition body onto the **system** prompt
(``Prompt.compose_agent/2``: framework + project memory + agent body).
opencode does something different for its plan mode: it appends a
``plan.txt`` fragment to the **last user message**, and on a
plan→build switch appends a separate ``build-switch.txt`` (with the
plan file path interpolated). Its built-in agents with their own prompt
file (``explore``, ``compaction``) *replace* the provider prompt
entirely rather than appending.

The systems-array approach has one clear advantage — the definition
stays stable across turns, so it is prompt-cacheable, whereas a
fragment appended to a user message changes with the message. The
message-fragment approach has another — the mode instruction sits
immediately next to the request it governs, and switching modes does
not rewrite (and thus uncache) the whole system prefix. We are on the
system-array side; whether plan should be, too, is open. See
``code_review.md`` T12/T13 for the related prompt gaps.

Still open (subagent slice)

5. **Model precedence** for subagents: definition ``model`` vs. session
   model vs. an inherited default. Claude Code's order (per-invocation >
   definition > env > session) is a good starting point, but it only
   matters once the ``task`` seam exists.
