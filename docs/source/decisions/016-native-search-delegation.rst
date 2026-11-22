.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

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

   **Amended by ADR 030** (2026-09-27): the Elixir fallback is gone —
   ``rg``/``fd`` are REQUIRED for ``grep``/``glob``, because the walk was
   a second, unconfined boundary. The delegation contract below (the
   result-schema guarantee, the physical re-check, the ``--no-config``
   rule, the ``Exec`` + sandbox path) stands unchanged; the "when
   available / when absent" selection is replaced by "present, or a
   clear refusal".

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

The second reason **did not survive ADR 030**: portability cannot be
bought with an unconfined BEAM walk when the whole model is "the sandbox
is the one boundary". ``rg``/``fd`` are therefore required; a host
without them cannot use the search tools (it can still use
read/write/edit/list_dir, whose confinement does not depend on them).
The result-schema guarantee — containment re-check, caps, one dialect —
is unchanged, and is now the whole reason the tools exist.

Decision
--------

Keep the native ``grep`` and ``glob`` tools as the **model-facing
contract** (one dialect, caps, a physical scope re-check) over an
external engine, and delegate to ``rg``/``fd``:

- At session start (or first use) the tool probes for ``rg`` (``grep``)
  and ``fd`` (``glob``) on ``PATH``.
- If present, the tool shells out to it and maps the output into the same
  result schema it returns today.
- **ADR 030: if absent, the tool returns a clear error naming the
  missing binary.** There is no Elixir fallback.

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
  could reject or reinterpret a valid pattern;
- **ADR 030: a non-``0``/``1`` exit is an error result**, not a fallback
  (there is nothing to fall back to).

The security argument: the sandbox is the boundary for every tool; the
native tool's schema (caps, the physical re-check) is defence in depth
and the model-facing contract.

Consequences
------------

- The best available search when the binaries exist; a clear refusal
  when they do not (``grep``/``glob`` need ``rg``/``fd``).
- One code path per tool. The reference dialect survives as pure
  functions (`GlobMatch`, the hidden rule) that FILTER the engine's
  output; the retired BEAM walk is gone entirely (ADR 030 removed the
  last `Containment.walk/3`, so `rg`/`fd` are the only engine and there
  is no unconfined fallback).
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
   would read differently fall back to a wide enumeration
   (``--glob '*'`` + ``--max-results``) filtered by the reference rule
   — since ADR 030 there is no Elixir walk to fall back to. ``rg`` no
   longer receives the caller's glob at
   all: it searches wide and the result is filtered by
   ``Glob.file_match?/3``.
2. **One hidden rule.** ``--hidden`` is passed so a search that *names* a
   hidden entry can find it, and the result is filtered afterwards
   (``Containment.filter_hidden/2``), so a pattern that did not ask cannot
   gain one. The rule covers *files* and directories alike
   (``Containment.hidden_entry?/1``), and the opt-in is POSIX spelling
   (``.gitignore``, ``.*``, ``.github/*``).
3. **Naming beats filtering at every layer** — ``path: ".github"`` or
   ``glob: ".env.example"`` is the same opt-in in both tools and both
   engines, and a named target is exempt from the skip list that would
   otherwise prune it (``path: "src/doc"`` searches it).
4. **The skip lists now mean the same thing.** ``fd --exclude <name>``
   also prunes a *file* of that name; the excludes are ``**/<dir>/**``, so
   only directories are pruned, like ``Containment.default_skip_dirs/0``.
5. **Errors are not results.** A non-zero exit falls back to the wide,
   filtered enumeration (fd reports "no matches" with exit 0 — the 0/1
   convention belongs to ``--quiet``); it is never formatted as a
   result.

The reference engine is now the definition: ``SearchDelegationTest``
compares every documented shape against the reference filter. That test
is the part that was missing — the previous tests used only rootless
patterns (``*.ex``, ``**/*.ex``), the one region where every engine
agreed by accident. Since ADR 030 there is no second engine to run off,
so the old "with the binary / with the probe forced off" pairing
collapsed into one filtered answer.

