Commands reference
==================

The commands the human can type in the composer, introduced by ``/`` at
a word boundary (ADR 034). ``/help`` in the program prints the same list;
``/`` opens a live-filtered palette. Every command is defined once, in
``CodingAgent.UI.Commands`` — this page is checked against that registry
by ``test/coding_agent/ui/commands_test.exs`` and
``test/coding_agent/docs/`` so the two cannot drift.

.. list-table::
   :header-rows: 1
   :widths: 26 52 22

   * - Usage
     - Meaning
     - Also
   * - ``/help``
     - Show this list.
     - ``ctrl-x h``
   * - ``/new``
     - Start a fresh session for this directory.
     -
   * - ``/sessions``
     - Switch to another session.
     - ``ctrl-x s``
   * - ``/model [name]``
     - Switch the model for the next turn. Without a name, opens the
       model list.
     - ``ctrl-x m``
   * - ``/agent [name]``
     - Switch the primary agent for the next turn. Without a name, cycles
       like Tab.
     -
   * - ``/export [md|json]``
     - Write this session as a transcript (default ``md``).
     -
   * - ``/undo``
     - Restore the working tree to the checkpoint taken before the last
       turn (files only; the conversation is kept). Repeated ``/undo``
       goes further back, up to ``checkpoint_depth``.
     -
   * - ``/compact``
     - Summarize the older context now, on demand, instead of waiting for
       an automatic limit. The summary runs in the background; a turn
       must not be in flight. "Nothing to compact" when the conversation
       is still too short.
     - ``ctrl-x c``
   * - ``/catalog``
     - Fetch llm_db's newest published model-catalog snapshot and re-cut it
       for the installed version (ADR 039). The download runs in the
       background; the sidebar's ``catalog`` date moves when it lands. The
       catalog also checks once a day on its own.
     -
   * - ``/subagents``
     - Open a subagent tab.
     - ``ctrl-x a``
   * - ``/tools``
     - Toggle the last tool call's output.
     - ``ctrl-x t``
   * - ``/sidebar``
     - Toggle the sidebar.
     - ``ctrl-x p``
   * - ``/debug``
     - Toggle the debug line.
     - ``ctrl-x d``
   * - ``/keymaps``
     - Show the key bindings.
     - ``ctrl-x k``
   * - ``/quit``
     - Leave the program.
     - ``ctrl-x q``

Notes
-----

- ``/`` is an ordinary character mid-word (``and/or`` stays text); it only
  opens the palette at a word boundary, the same rule as ``@`` (ADR 032).
- ``escape`` closes the palette without running anything.
- A command left in the field is executed on send, so a paste or an
  unopened palette still works.
