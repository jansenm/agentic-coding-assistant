:orphan:

Read tools delegate to ripgrep/fd when available, fall back to Elixir
=====================================================================

.. adr::
   :id: 016
   :status: Accepted
   :date: 2026-09-17
   :tags: tools, grep, glob, dependencies

.. note::
   Accepted 2026-09-17. Records a decision made while designing ADR 015:
   once ``shell`` runs confined and allow-by-default, the native
   ``grep``/``glob`` tools are no longer the only way to search without a
   prompt, so their justification changes. Implemented in
   ``Core.External`` + the two tools.

Context
-------

The native ``grep`` and ``glob`` tools exist for two reasons (ADR 002,
``Tools.Grep`` moduledoc):

1. **Avoid approval prompts.** Shell searches were 24 of 112 calls in the
   live session; the tools let read-only work proceed without a ``y``.
2. **Pure Elixir, no external binary.** A guaranteed-present, NIF-free
   search that works wherever the assistant runs.

ADR 015 removes the first reason. With ``shell`` allow-by-default *inside*
the sandbox, an agent is free to run ``rg`` directly — no prompt — and
``rg`` is a materially better search engine than our implementation
(PCRE2, ``.gitignore`` awareness, speed, binary detection). Amendment 2
to ADR 010 ("a shell grep duplicate should use the grep tool") becomes
actively questionable in confined mode: it pushes the agent from the
better engine to the worse one.

The second reason survives and is not small: portability (machines with
no ``rg``/``fd``, and no network to install one), the ``Sandbox.None``
fallback path (macOS, hardened hosts) where there is no confinement at
all, and a stable, containment-checked, capped result schema independent
of a foreign tool's configuration.

Decision
--------

Keep the native ``grep`` and ``glob`` tools as the **fallback and the
containment guarantee**, and let them **delegate to ``rg``/``fd`` when
those binaries are present**:

- At session start (or first use) the tool probes for ``rg`` (``grep``)
  and ``fd`` (``glob``) on ``PATH``.
- If present, the tool shells out to it and maps the output into the same
  result schema it returns today.
- If absent, it uses the existing pure-Elixir implementation, unchanged.

Delegation is not an Elixir dependency (no NIF, no library, no build-time
requirement), so it is compatible with ADR 002. It is a runtime use of an
optional external binary, exactly like ``git``.

Containment under delegation
----------------------------

The native tools guarantee containment themselves (scope checks, skipping
``_build``/``deps``/``.git``, result and byte caps). A delegated run
preserves that:

- the requested ``path`` is scope-checked *before* the external tool runs,
  and **every returned path is re-checked physically** against the scope —
  never trust the external tool's traversal;
- **``--no-config`` is mandatory for ``rg``.** ``RIPGREP_CONFIG_PATH`` can
  carry ``--pre=<command>``, which executes an arbitrary program on every
  file — measured, it ran. The environment must not be able to influence
  the invocation. ``--no-ignore`` is also set so our skip rules (not the
  repo's ``.gitignore``) decide what is searched;
- excludes use ``!**/<dir>/**`` (``rg``) and ``--exclude <dir>`` (``fd``)
  so a *nested* ``src/_build`` is pruned the way the Elixir walk prunes it;
- for ``rg``, an **include glob precedes the excludes**: a later include
  re-adds what an earlier exclude removed (measured), so excludes go last;
- ``rg`` does not follow symlinks in traversal (measured), and its
  explicit-file case is caught by the pre-check above; ``fd`` output is
  re-checked the same way;
- the ``rg`` probe requires the ``pcre2`` feature, because the tool's
  patterns come from Elixir's ``Regex`` (PCRE) — a Rust-regex-only build
  could reject or reinterpret a valid pattern, so we fall back instead;
- any non-``0``/``1`` exit (including a pattern Elixir accepts but PCRE2
  rejects) triggers the Elixir fallback rather than an engine-specific
  error.

The security argument is layered: in confined mode the sandbox is the
boundary and the native tool is defence in depth; in ``Sandbox.None``
mode the native tool's own containment is the only boundary, which is
today's status quo.

Consequences
------------

- Best available search when the binaries exist; no regression when they
  do not.
- Two code paths per tool, both tested (the fallback is forceable in tests
  via ``External.put/2``); the Elixir path cannot be deleted because it is
  the fallback.
- Amendment 2's shell-grep redirect stays as UX steering but should not
  claim the native tool is *better* — only that a tool call is cleaner
  than shell.
- A future option, not in scope here: a single ``search`` tool that picks
  the engine internally, so the model does not choose between ``grep`` and
  shell. Revisit after the delegation exists.
