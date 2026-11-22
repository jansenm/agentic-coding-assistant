.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

CLI reference
=============

The entry point is the ``mix tui`` task. Flags are parsed with
``OptionParser`` in ``CodingAgent.Mix.Tasks.Tui``; this page is the human
view of the same options.

Usage
-----

.. code-block:: text

   mix tui [OPTIONS] [PROMPT]

``PROMPT`` (optional) is sent as the first user message of a fresh
session. Without it the composer starts empty.

Options
-------

.. list-table::
   :header-rows: 1
   :widths: 24 76

   * - Flag
     - Meaning
   * - ``--resume <id>``, ``-r <id>``
     - Continue a persisted session instead of starting a fresh one.
       ``<id>`` may be a unique prefix, as in the session picker.
   * - ``--agent <name>``
     - Start the session on this primary agent definition instead of the
       configured default.
   * - ``--store <name|path>``
     - Use a specific session store: a name from ``config.toml``
       ``[stores]`` or a filesystem path. Equivalent to setting
       ``AGENT_STORE`` (see below). The store is pinned before the UI
       mounts, so the picker, the log path and every session read agree.

The working directory the task is invoked in becomes the session's scope
root (ADR 030): file tools and the sandbox are bounded to it, and project
config / ``AGENTS.md`` are resolved relative to it. A scope inside a git
checkout resolves repository-level config and ``.git`` up to the repo
root; the scope root itself stays the working directory.

Environment variables
---------------------

Layer order (weakest to strongest): built-in defaults, global
``~/.config/coding-agent``, project ``.coding-agent``, then these:

.. list-table::
   :header-rows: 1
   :widths: 26 74

   * - Variable
     - Effect
   * - ``AGENT_MODEL``
     - Override the model for this run. Same value as ``config.toml``
       ``model =``; takes precedence over it.
   * - ``AGENT_STORE``
     - Select the session store: a name from ``[stores]`` or a path. Same
       effect as ``--store`` (the flag wins when both are given).
   * - ``XDG_CONFIG_HOME``
     - Base for the global config directory (default ``~/.config``).
   * - ``XDG_DATA_HOME``
     - Base for the credentials directory (default ``~/.local/share``);
       ``auth.toml`` lives here.
   * - ``XDG_STATE_HOME``
     - Base for the state directory (default ``~/.local/state``); the
       session store DB and ``tui.log`` live here.

Files
-----

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Path
     - Purpose
   * - ``~/.config/coding-agent/config.toml``
     - Global configuration (see :doc:`configuration`).
   * - ``~/.config/coding-agent/ui.toml``
     - Global key bindings.
   * - ``~/.config/coding-agent/permissions.toml``
     - Global permission policy.
   * - ``~/.local/share/coding-agent/auth.toml``
     - Provider credentials (never read from a project).
   * - ``<scope_root>/.coding-agent/*.toml``
     - Project overrides, resolved at the scope root (the directory the
       session was started in; not searched for upward).
   * - ``<scope_root>/.coding-agent/agents/*.md``
     - Project agent definitions.
   * - ``<scope_root>/AGENTS.md``
     - Project memory (scope root only; subdirectory files are read on
       demand).
   * - ``~/.local/state/coding_agent/``
     - Session store DB and ``tui.log``.
