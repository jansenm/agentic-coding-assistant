.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

Configuration Landscape
=======================

.. note::
   **Forward-looking page.** This describes the configuration surface as
   if the assistant were feature-complete. It is the map we build
   toward; individual pieces ship with the phases and ADRs noted
   throughout. Nothing here contradicts an ADR — where a page and an
   ADR differ, the ADR is authoritative.

The assistant reads several configuration sources. They fall into two
layers whose separation is a hard rule (see
:doc:`../decisions/010-permission-gate`):

- **Instructions** — prose the agent *reads* to know how to behave.
- **Policy & definition** — structured data the *runtime* enforces or
  loads. Instructions can never change policy.

Files in the project
--------------------

``AGENTS.md`` (scope root, optional)
    The de-facto standard instruction file (consumed as-is; we do not
    compete with it). Conventions, building commands, "never touch X".
    Read at the **scope root** — the directory the session was started
    in; we do not search up or down. The convention also places
    ``AGENTS.md`` in subdirectories, and those apply when the agent
    works *there*, so the section tells the model they exist and to read
    them with ``read_file`` (rather than walking down, which is
    unbounded in a monorepo). A single ``AGENTS.md`` at the scope root
    is read at session start into the system prompt (64 KiB cap,
    truncating; missing file is normal). A user-level fallback
    (``~/.config/coding-agent/AGENTS.md``) remains phase-5 work.

``.coding-agent/permissions.toml`` (scope root, optional)
    The policy layer: tool enablement and the permission table
    ``(path-pattern) → allow | ask | deny``, later role-scoped via
    ``[agents.<role>.permissions]``. May only *tighten* what the user
    layer allows (non-elevation). Malformed file = refuse to start.
    *Ships in slice 2b* (ADR 010).

``.agents/skills/<name>/SKILL.md`` (project, optional)
    Project-local skills: an instruction package with a YAML frontmatter
    (``name``, ``description`` — the description is what the model sees
    when deciding to load) and Markdown/Prose- or resource-files body.
    Follows the emerging ``.agents/skills`` directory convention used by
    several agent tools, so skills can be shared between tools
    verbatim. Project skills override same-named user skills. *Ships in
    phase 6* (ADR to come).

``.agents/agents/*.toml`` (project, optional)
    Project-local agent definitions (ADR 007): name, role description,
    system prompt refs, tools, permission entries, scope. Data, not
    code, per the matrix ADR.

``permission`` frontmatter in agent/skill definitions (honored)
    The agents convention (as used by opencode et al.) carries an
    optional ``permission`` section in the frontmatter of agent and
    skill files — e.g. a ``maven.md`` agent declaring
    ``permission.edit."**/pom.xml" = allow``. We honor it as **one more
    restrictive-only layer** in the ADR 010 merge: a definition's
    permission entries participate in the most-restrictive-wins
    intersection like any other layer. A template may *narrow* what its
    agent can do (the natural use: a read-only analyzer denying edit
    and bash for itself) and may pre-*narrow-then-ask* (scoping its own
    edit patterns), but an ``allow`` in a definition never overrides an
    ``ask``/``deny`` from user or repo layers — authority still
    originates only there. This keeps `.agents/…` definition files
    portable between tools while the enforcement floor stays ours.

Files in the home directory
---------------------------

``~/.config/coding-agent/permissions.toml``
    The user's own global limits. The *most restrictive wins* rule
    (ADR 010) makes this the floor no project file can undercut. This
    is where "never allow shell in any project" lives.

``~/.config/coding-agent/agents/*.toml``
    User-level agent definitions available to all projects (the
    Jenkinsfile specialist you want in every workspace, not per repo).

``~/.agents/skills/<name>/SKILL.md``
    User-level skills, following the same directory convention as the
    project level (this is the directory several agent tools already
    scan for skills).

``~/.agents/agents/*.toml`` (considered)
    The ``.agents`` convention also suggests user-level agents here.
    We lean to keeping *our* user-level data under
    ``~/.config/coding-agent/`` for clarity, but a compatibility read
    of ``~/.agents`` is conceivable once the format stabilizes. Open
    point; decided with phase 5.

Precedence summary
------------------

========================= ================= ==========================
Layer                     Instruction       Policy / definition
========================= ================= ==========================
built-in defaults         framework prompt  ADR 010 class defaults
user home directory       fallback AGENTS   ~/.config/coding-agent/*
scope root                AGENTS.md         .coding-agent/
per-agent/role            prompts refs      [agents.<role>] entries
========================= ================= ==========================

Two merge rules run through everything:

1. **Instructions compose** — more specific files are appended to the
   prompt in precedence order; a deeper file may refine, never
   contradict, the policy layer.
2. **Policy intersects** — the most restrictive decision wins across
   layers (ADR 010); nothing in an instruction file can change that.

What deliberately does *not* exist
----------------------------------

- No ``.env``-style per-project secrets in policy files — API keys stay
  in the environment (ADR 008).
- No per-project override that can *grant* rights (non-elevation).
- No competing prose format next to AGENTS.md.