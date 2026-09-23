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
- the delegated process runs through ``Exec`` under the read-only sandbox
  profile, the same ``Port.open`` + ``Sandbox.wrap`` path as
  ``shell``/``git`` — not a bare ``System.cmd``;
- excludes use ``!**/<dir>/**`` (``rg``) and ``--exclude **/<dir>/**``
  (``fd``) so a *nested* ``src/_build`` is pruned the way the Elixir walk
  prunes it — and, for ``fd``, so a same-named *file* is not pruned (a
  bare name prunes files too; measured);
- for ``rg``, an **include glob is not used at all** (see the 2026-09-23
  amendment): ``rg`` searches wide and the result is filtered by the
  reference rule, so its own glob dialect never decides what a match is;
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

Amendment 2026-09-23: the delegation was a silent divergence
------------------------------------------------------------

**Status: Accepted (amendment to the accepted ADR 016).**

The decision above assumed "maps the output into the same result schema",
i.e. that the external engines answer the *same question* as the Elixir
implementation. Measured, they did not — the two paths were two search
tools wearing one name:

- ``fd --glob`` matches the entry **name**, not the path. Every pattern
  with a ``/`` returned nothing whenever ``fd`` was installed:
  ``lib/**/*.ex`` found 0 files where the walk found 59, ``lib/*.ex`` 0
  where the walk found 1. The documented shapes in ``Tools.Glob``'s
  description and parameter docs (``"lib/**/*.ex"``, ``"**/*.toml"``) were
  exactly the broken ones; only ``**/*`` and ``*.ex`` happened to agree.
- ``fd`` and ``rg`` answer with **smart case** by default; the walk is
  case-sensitive. ``*.EX`` matched ``top.A.EX`` in one path, not the other.
- ``fd``'s dialect is **richer** than ours: ``[...]`` classes, a leading
  ``!`` as negation, ``\`` as a quote, and path normalization for ``./x``,
  ``x/``, ``a//b``. ``[ab].ex`` listed ``a.ex`` and ``b.ex`` under ``fd``
  and nothing in the walk.
- ``rg``'s ``--glob`` was passed straight through, so a *narrower* filter
  than ours silently **dropped** matches the reference engine finds
  (``--glob '*.ex'`` listed a hidden ``.hidden.ex``), and an invalid glob
  printed an error on stdout, i.e. reached the model as a search result.
- None of this was visible to ``fd``: a non-zero exit was formatted as a
  result, and ``Exec`` merges stderr into stdout.

The fix keeps the decision (delegate) and makes the contract real:

1. **One dialect, enforced by the reference engine.** ``fd`` is called
   root-anchored and absolute (``--absolute-path --full-path``, pattern
   ``Path.join(root, pattern)``) so a path pattern means a path, and
   ``--case-sensitive`` so case means case. Patterns that fd's dialect
   would read differently stay on the reference engine
   (``fd_dialect?/1``). ``rg`` no longer receives the caller's glob at
   all: it searches wide and the result is filtered by
   ``Glob.file_match?/3``.
2. **One hidden rule.** ``--hidden`` is passed so a search that *names* a
   hidden entry can find it, and the result is filtered afterwards
   (``Containment.filter_hidden/2``), so a pattern that did not ask cannot
   gain one. Before this the walk and the external engines disagreed about
   *files* too (the walk pruned hidden directories only, ``fd``/``rg``
   prune hidden files as well); the walk now applies the same rule, and
   the opt-in is POSIX spelling (``.gitignore``, ``.*``, ``.github/*``).
3. **Naming beats filtering at every layer** — ``path: ".github"`` or
   ``glob: ".env.example"`` is the same opt-in in both tools and both
   engines, and a named target is exempt from the skip list that would
   otherwise prune it (``path: "src/doc"`` searches it).
4. **The skip lists now mean the same thing.** ``fd --exclude <name>``
   also prunes a *file* of that name; the excludes are ``**/<dir>/**``, so
   only directories are pruned, like ``Containment.default_skip_dirs/0``.
5. **Errors are not results.** A non-zero exit falls back (fd reports
   "no matches" with exit 0 — the 0/1 convention belongs to ``--quiet``).

The reference engine is now the definition and both engines are measured
against it: ``SearchDelegationTest`` "engine agreement" runs every
documented shape twice, once with the binary and once with the probe
forced off, and asserts the two answers are identical. That test is the
part that was missing — the previous tests used only rootless patterns
(``*.ex``, ``**/*.ex``), the one region where every engine agreed by
accident.

