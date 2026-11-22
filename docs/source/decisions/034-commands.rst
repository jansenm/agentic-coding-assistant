.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

Slash commands: one registry for dispatch, help and the reference
==================================================================

.. adr::
   :id: 034
   :status: Accepted
   :date: 2026-09-29
   :tags: ui, commands, discovery, docs

.. note::
   Accepted and implemented 2026-09-29. Answers T7 in the ``TODO.md``
   "rival opencode" list. Introduces a ``/``-triggered command surface in
   the composer, backed by ONE command registry
   (``CodingAgent.UI.Commands``) that also feeds the ``ctrl-x`` menu,
   ``/help`` and the reference page, so dispatch, help and docs cannot
   drift. The action set (including ``/new``) is wired; ``/undo`` joined
   later with ADR 036.

Context
-------

Every action the TUI offers is reachable, but only through three
discovery surfaces that do not share a source:

1. **Keymap bindings** (ADR 011) — ``ctrl-t`` toggles tool output,
   ``Tab`` switches the agent, ``esc`` stops. A human must read the
   keymap popup (or the ADR) to find them.
2. **The ``ctrl-x`` menu** (``UI.Menu``) — "switch session", "switch
   model", "subagents", "toggle sidebar", "show keymaps", "quit". This
   is the closest thing to a command list today, but it is keyed by a
   single letter and is not searchable or documented.
3. **The ``@`` file picker** (ADR 032) — inserts a path.

The gaps this produces, seen while dogfooding:

- **"How do I do X?" has no in-program answer.** There is no ``/help``.
  A new user (and the owner, weeks later) has to remember chords.
- **The action set is invisible to the model of the program.** The menu
  table, the keymap and the docs each list actions separately. Adding
  "compress context" or "export" means remembering to touch three
  places, and nothing fails if one is missed.
- **Commands have no home for arguments.** opencode's ``/command``
  form (and every chat CLI's) is the natural place for ``/model
  <name>`` or ``/export md``; a single letter cannot carry that.

opencode ships a palette/slash surface. We do not need its full
extension surface (custom commands from Markdown); we need the
discoverable core with a single source of truth.

Decision
--------

**1. A command registry is the ONE definition of every user-visible
command.** A new module, ``CodingAgent.UI.Commands``, holds a list of
command records as data — the same discipline as ``UI.Keymap``,
``UI.Menu`` and the tool schemas::

    %{
      name: "sessions",          # typed after `/`
      summary: "switch session",
      usage: "/sessions",        # how to invoke it, arguments included
      run: :switch_session       # the TUI action it resolves to
    }

The record carries ``name``, ``summary``, ``usage`` and the action atom
the TUI already knows (``run_menu_action/2`` in ``tui.ex``). The
registry is pure data with no TUI state, so it is testable and
documentable in isolation.

**2. ``/`` in the composer opens a live-filtered command palette.** The
trigger is TEXT at a word boundary, exactly like ``@`` (ADR 032): ``/``
must stay typable mid-message. Typing narrows by name and summary;
``enter`` runs the selected command. The palette reuses the ADR 032
bottom-anchored popup geometry, not a new surface. A ``/command`` typed
without the popup (a paste, or a completed word) is also executed on
send when the whole trimmed input is a single known command — so both
interactive and typed use lead to the same place.

**3. ``/help`` lists every command from the registry.** ``/help`` opens
a popup whose rows are ``usage`` plus ``summary``, generated from
``Commands.all/0``. There is no second hand-written help text to drift.

**4. The ``ctrl-x`` menu is defined FROM the registry.** ``UI.Menu``'s
item list becomes a projection of the command records that also declare
a fast-path letter. The menu keeps its timing behaviour (letter within
1 s fires, otherwise the popup); it stops being an independent table.
An action reachable both ways (``/sessions`` and ``ctrl-x s``) is one
record with two triggers.

**5. The reference page is generated-checked against the registry.**
``docs/source/reference/commands.rst`` lists the commands; a drift test
reads ``Commands.all/0`` and fails if a command is missing from the
page (mirroring the configuration-reference test). The page and
``/help`` answer from the same data.

Consequences
------------

- One place to add a command. A new command lands in the registry, and
  the palette, ``/help`` and the reference follow or a test fails.
- The existing menu actions (``switch_session``, ``switch_model``,
  ``subagents``, ``toggle_tool_output``, ``toggle_sidebar``,
  ``show_keymaps``, ``quit``) become commands; the menu is a view.
- Arguments get a syntax (``usage``) without a parser framework: v1
  commands take at most a simple trailing token (``/model <name>``,
  ``/export md``), split on whitespace. A command that needs more opens
  its existing popup instead.
- ``/`` at the **line start** opens the palette; any ``/`` after text
  (mid-word like ``and/or``, or after a space like ``run /bin/ls``)
  stays text. Review F2 tightened this from "word boundary" to "line
  start": a spilled path the agent was invited to read
  (``/tmp/spill/...``) stands at the word start and was captured by the
  palette, so the message could not be typed. This is stricter than the
  ``@`` trade (ADR 032), and matches ``Commands.parse/1``, which only
  reads a leading ``/name`` as a command.
- **A slash that was not a command is written back.** Esc, or Enter with
  no matching command, returns the typed ``/query`` to the composer
  (review F2) — the same "the user typed it, do not swallow it" rule
  ``@`` got on an error (review F7). Before, the message vanished.

Open questions
--------------

1. **``/undo`` and ``/compact``.** ``/undo`` shipped as a command (ADR
   036, 2026-09-29) once the checkpoint machinery existed, and
   ``/compact`` (ADR 037, 2026-09-29) once compaction had a manual entry
   point — each was a registry record plus one TUI resolver clause, not a
   new mechanism. ``/compact`` was on the original T7 wish list
   (``/new``, ``/sessions``, ``/models``, ``/compact``, ``/export``,
   ``/undo``, ``/help``) and was overlooked when the first registry
   shipped; it is now reconciled.
2. **User-defined commands.** opencode lets commands come from Markdown
   files. Deferred: it needs a prompt-template mechanism and a trust
   story. The registry shape (``name``/``summary``/``usage``/``run``)
   would need a ``prompt`` variant, not just an action atom.
3. **Aliases.** ``/q`` for ``/quit``? Start with the canonical name per
   command; add aliases only if a real one bites.
4. **Should the keymap popup also fold into ``/help``?** Today
   ``show_keymaps`` lists bindings. Keeping key bindings and commands
   separate is honest (different vocabularies), but a unified
   "everything you can do" view may win later.
