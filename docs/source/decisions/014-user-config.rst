:orphan:

User configuration: XDG layers, one credential file
===================================================

.. adr::
   :id: 014
   :status: Accepted
   :date: 2026-09-13
   :tags: configuration, secrets, xdg

.. note::
   Accepted 2026-09-13. Motivated by model switching (the model was
   compile-time only) and the cloud-direct ollama probe, which needs a
   place for the API key that is not per-project and not in the repo.

Context
-------

Configuration accumulates across several consumers:

- the keymap (``Keymap.merge/2`` accepts overrides, but nothing loads
  a file — the ``~/.config/coding-agent/ui.toml`` path was documented
  but never read),
- permissions (the user-side layer came from an app-env path that no
  config set; the repo-side file lived at the scope root as
  ``agent-permissions.toml``),
- the model and compaction settings (compile-time ``config.exs``),
- credentials (env-only per ADR 008, which made keyless-local versus
  keyed-cloud ollama awkward — the ``@keyless_providers`` special
  case).

Decision
--------

Four TOML files. TOML everywhere (one format; JSON felt arbitrary).

**Global (user level), one backup-able directory:**

``~/.config/coding-agent/``

- ``config.toml`` — default model, provider connection info (base_url,
  which env var names the key), compaction trigger, reasoning effort.
- ``ui.toml`` — ``[keys]`` keymap overrides; future ``[menus]``.
- ``permissions.toml`` — the user-side policy layer.

**Secrets are not in this directory** so that archiving
``~/.config/coding-agent`` cannot leak keys:

``~/.local/share/coding-agent/auth.toml``

- per-provider API keys **only** — the credential file is a password
  file, nothing else (revised 2026-09-13: connection info moved to
  ``config.toml``)::

     [ollama]
     api_key = "..."

Connection info (endpoints, provider routing) lives in
``config.toml`` under ``[providers.<name>]``::

     # provider = "openai": ride the :openai provider module (an
     # OpenAI-compatible backend) — req_llm's :ollama provider never
     # sends auth, so cloud models need the indirection
     [providers.ollama_cloud]
     provider = "openai"
     base_url = "https://ollama.com/v1"

**Per-project (overlays the global layers, discovered at the scope
root):**

``<project>/.coding-agent/``

- ``config.toml``, ``ui.toml``, ``permissions.toml`` — same shapes,
  merged over the global files.

Layer order, weakest to strongest:

1. built-in defaults
2. global ``~/.config/coding-agent/<file>.toml``
3. project ``<project>/.coding-agent/<file>.toml``
4. environment / CLI flags (unchanged: env still wins)

``auth.toml`` is **global only, not overridable per project**: secrets
in a repo risk accidental commits, and there is one account. Revisit
if a real need (per-repo accounts) appears.

``agent-permissions.toml`` at the scope root moves into
``.coding-agent/permissions.toml``; the old path is still read (after
the new one) during the transition.

Consumer-facing changes
-----------------------

- New ``Core.UserConfig``: resolves the four files, deep-merges the
  layers into a typed struct, exposes the pieces (model, ui overrides,
  permission layers, provider credentials).
- Credentials resolve through one seam (``auth provider -> credential``
  or ``nil``): env first, then ``auth.toml``. The
  ``@keyless_providers`` special case becomes "use the credential if
  one resolves; connect keyless otherwise" — a keyed ollama cloud and
  a keyless local proxy are the same code path.
- A future Secret Service portal (org.freedesktop.Secret) slots in
  behind the same credential seam as a backend replacement for the
  file; call sites never change.

Consequences
------------

- Backing up ``~/.config/coding-agent`` is safe: no secrets there.
- Model switching reads the default from ``config.toml`` at mount and
  can override per session at runtime (menu), independent of the
  compile-time default.
- ``.coding-agent/`` in a repo template gets a gitignore entry for
  ``auth.toml`` anyway (defence in depth) even though the loader will
  not read a project-local one.