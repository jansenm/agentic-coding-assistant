:orphan:

Read tools delegate to ripgrep/fd when available, fall back to Elixir
=====================================================================

.. adr::
   :id: 016
   :status: Proposed
   :date: 2026-09-17
   :tags: tools, grep, glob, dependencies

.. note::
   Proposed 2026-09-17 — no code yet. Records a decision made while
   designing ADR 015: once ``shell`` runs confined and allow-by-default,
   the native ``grep``/``glob`` tools are no longer the only way to search
   without a prompt, so their justification changes.

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

The native tools currently guarantee containment themselves (scope
checks, skipping ``_build``/``deps``/``.git``, result and byte caps). A
delegated run must preserve that guarantee, so the tool:

- passes an explicit path scope and re-checks every returned path against
  it (never trusts the external tool's traversal),
- disables the external tool's own ignore/walk behaviour where it would
  escape the scope (e.g. ``--no-config``/``--no-ignore`` handling, a
  fixed ``--max-count`` and output cap),
- keeps the existing result cap and byte cap applied to the external
  output as well.

The security argument is layered: in confined mode the sandbox is the
boundary and the native tool is defence in depth; in ``Sandbox.None``
mode the native tool's own containment is the only boundary, which is
today's status quo.

Consequences
------------

- Best available search when the binaries exist; no regression when they
  do not.
- Two code paths per tool, both tested; the Elixir path cannot be deleted
  because it is the fallback.
- Amendment 2's shell-grep redirect stays as UX steering but should not
  claim the native tool is *better* — only that a tool call is cleaner
  than shell.
- A future option, not in scope here: a single ``search`` tool that picks
  the engine internally, so the model does not choose between ``grep`` and
  shell. Revisit after the delegation exists.
