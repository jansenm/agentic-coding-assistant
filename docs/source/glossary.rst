.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

Glossary
========

.. glossary::

   Agent loop
      The core cycle: build context, call the LLM, execute tool calls from
      the response, append results, repeat until the model produces a final
      answer.

   Working context
      The message history sent to the LLM on each call; subject to
      compaction. Synonymous with *agent view*.

   Agent view
      The compact, LLM-facing form of a session's history — what is sent on
      the next request. Compaction mutates it.

   Display view
      The immutable, user-facing transcript of a session: every user
      message, assistant reply, reasoning block, tool call and informational
      note, in order. Compaction never touches it.

   Dual-view pattern
      Keeping the agent view and the display view separate, so a resumed
      session renders its true history (including reasoning that was never
      in the agent view) rather than a lossy, compacted reconstruction.

   Session
      A durable unit of agent work: one conversation with its full history,
      agent state and gate state; runs in one supervised OTP process. A
      session belongs to exactly one **store**.

   Store
      The selectable place sessions are kept: **one SQLite database file
      that holds many sessions**. Several stores (e.g. one per client or
      project) are several files; one is chosen explicitly, never resolved
      across stores automatically. Selected by ``--store`` on ``mix tui``,
      the ``AGENT_STORE`` environment variable, or ``config.toml``
      ``store =`` / a ``[stores]`` name (ADR 020, R16). The default store
      is ``~/.local/state/coding_agent/store.db``.

   Scope root
      The directory a session's file and shell tools are confined to. It is
      *data inside* the session (a column/field), not a property of the
      store: moving or renaming a directory orphans nothing, and a session
      opened elsewhere still knows where it ran.

   Scratch
      A per-session host directory (``$TMPDIR``-based) bound over ``/tmp``
      inside the sandbox, so ``/tmp`` persists across tool calls within a
      session but is gone after a reboot (ADR 022).

   Compaction
      Summarizing/truncating old turns in the working context (agent view)
      while keeping recent turns verbatim. Summaries replace messages in
      the agent view only.

   Confinement (sandbox)
      Running each tool invocation inside an OS sandbox (bubblewrap on
      Linux) that bounds what the *process* can reach, rather than vetting
      the command text (ADR 015).

   Mount schema
      The declarative ``rw`` / ``ro`` / ``hide`` path directives that shape a
      confined process's view of the filesystem; user-configurable and
      non-elevating (a project layer may only tighten).

   Escalation
      A coarse grant a confined call must request explicitly and a human
      approves — network access, or writing ``.git``. Never inferred from
      command text.

   Permission gate
      The checkpoint before state-changing tool calls that decides
      ``allow`` / ``ask`` / ``deny`` by policy; an ``ask`` pauses the
      session for a human decision (approve / edit / reject).

   HITL (human-in-the-loop)
      Pausing an agent before executing sensitive tool calls and resuming
      after human approval (allow / edit / reject). The human side of the
      permission gate.

   Containment
      The file-tool guarantee that every path is resolved physically
      (symlinks followed) and must stay inside the scope root — fail-closed,
      enforced before any read or write.

   Surface (UI)
      A region the interface paints on — ``base`` (the transcript and the
      live band, terminal default), ``chrome`` (overlays: menu, picker,
      dialog, and the composer panel), ``sidebar`` — each with its own
      background. A role resolves *on* a surface. The ``base`` region is
      not only the reading area: it also carries the status band above the
      input, which is how that band stays distinguishable from the field
      (ADR 018 amendment).

   Live band (UI)
      The permanent one-row status area between the transcript and the
      input field: which agent and model are executing the *running* turn
      (while one runs) plus the status glyph, word and elapsed context.
      Distinct from the composer's setup row below the field, which names
      what the *next* input will use — Tab switches the latter while a
      running turn keeps its own (ADR 018 amendment). Painted on ``base``,
      one cell of padding on all four sides.

   Role (UI)
      The meaning of a piece of text, independent of colour and surface:
      ``text``, ``muted``, ``emphasis``, ``info``, ``success``, ``warning``,
      ``error``, ``agent``, ``model``, ``user``, ``accent``, ``reasoning``.
      Colours live in one palette; call sites name the role.

   MCP (Model Context Protocol)
      Standard protocol for connecting agents to external tools and
      resources; planned as a later tool subsystem.