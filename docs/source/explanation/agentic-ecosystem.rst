.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

The agentic protocol ecosystem
==============================

Around the harness a set of wire protocols has formed, each answering a
different question: who drives whom, who may touch which data, and who
draws the screen. They are easy to confuse because three of them shorten
to the same acronym and two more differ by one letter.

This page is the map: what each layer is for, how the protocols relate,
and which of them this harness speaks, plans to speak, or deliberately
does not. It is a **snapshot of October 2026** — the field moves monthly,
and a claim below is only as good as the date next to it.

The picture
-----------

.. mermaid::

   flowchart LR
       subgraph editor["Editor / IDE"]
           ACPClient[ACP client]
           LSPClient[LSP client]
           DAPClient[DAP client]
       end
       ACPClient <-->|ACP| Harness["Harness<br/>session + agent loop"]
       LSPClient <-->|LSP| LS[Language server]
       DAPClient <-->|DAP| Debug[Debug adapter]
       Harness <-->|MCP| Servers[Tool and data servers]
       Harness <-->|A2A| Peers[Other agents]
       Harness -->|AG-UI events| App[User-facing application]
       Harness -.->|A2UI widget JSON| App

The arrows are not interchangeable. ``ACP`` makes the harness a *server*
an editor drives; ``MCP`` makes it a *client* of tools; ``A2A`` makes it
a peer of other agents. ``LSP``/``DAP`` stay on the editor side of the
line; an agent borrows them, it does not implement them.

.. list-table::
   :header-rows: 1
   :widths: 20 16 18 46

   * - Layer
     - Protocol
     - Direction
     - Carries
   * - Editor ↔ agent
     - ACP (Agent Client Protocol)
     - client (editor) → agent, bidirectional JSON-RPC
     - session create/load, prompt, cancel, **permission requests**, and
       file/terminal operations the agent delegates back to the editor.
       Local agents over stdio; remote over HTTP/WebSocket (still in
       progress). Reuses MCP's JSON shapes where it can; user-visible text
       defaults to Markdown.
   * - Agent ↔ tools and data
     - MCP (Model Context Protocol)
     - agent (host/client) → server
     - tools, resources, prompts, sampling, and elicitation (a server asks
       the user for JSON-Schema-validated input)
   * - Editor ↔ language intelligence
     - LSP (Language Server Protocol)
     - editor → language server
     - definitions, references, hover, symbols, diagnostics
   * - Editor ↔ execution
     - DAP (Debug Adapter Protocol)
     - editor → debug adapter
     - breakpoints, stepping, stack frames, expression evaluation
   * - Agent ↔ agent
     - A2A (Agent2Agent)
     - agent → agent
     - discovery through an Agent Card at
       ``/.well-known/agent-card.json``; tasks, artifacts, streaming
       (JSON-RPC 2.0, SSE). Now stewarded by the Agentic AI Foundation.
   * - Agent backend ↔ frontend
     - AG-UI (Agent–User Interaction)
     - bidirectional events
     - token/tool-call events, shared state with streamed deltas, HITL
       interrupts, generative-UI payloads. A client need not be a browser.
   * - Agent → UI payload
     - A2UI, Open-JSON-UI
     - agent → renderer
     - a declarative component tree drawn from a fixed **catalog**; the
       client renders it natively, so no arbitrary HTML or JavaScript
   * - Tool result → UI payload
     - MCP Apps
     - server → client
     - a sandboxed HTML app attached to a tool result, instead of a
       component tree (the earlier community project was called MCP-UI)
   * - Money
     - AP2, UCP, Agentic Commerce Protocol
     - agent ↔ merchant / PSP
     - payment mandates, checkout, commerce flows
   * - Discovery and directory
     - ANP, AGNTCY
     - network-layer
     - agent discovery (DID-based), directories, observability

Three protocols called ACP
--------------------------

This is the single most common source of confusion, including in this
repository's own notes.

.. list-table::
   :header-rows: 1
   :widths: 30 22 48

   * - Name
     - Origin
     - What it standardizes
   * - **Agent Client Protocol**
     - Zed
     - editor/IDE ↔ coding agent. **This is what "ACP" means here.**
   * - **Agent Communication Protocol**
     - IBM Research / BeeAI, Linux Foundation
     - agent ↔ agent over REST, with a registry. The project joined forces
       with A2A in 2025; the name survives mostly in older articles.
   * - **Agentic Commerce Protocol**
     - OpenAI and Stripe
     - checkout inside a chat product. Nothing to do with editors or
       agents talking to each other.

``ROADMAP.md`` and ADR 007 use "ACP/MCP" as shorthand for agent
interoperability in general. The two are different directions and belong
to different rows of the table above: MCP is how the harness reaches
tools, ACP is how an editor reaches the harness.

AG-UI and A2UI are different layers
-----------------------------------

The remembered sentence — "the agent emits JSON and the client renders it
as a dialog" — describes **A2UI**. But A2UI is a *payload format*, not a
connection, and it is usually carried by **AG-UI**, which is the
connection:

- **AG-UI** is the runtime channel between an agent backend and a
  user-facing application: a stream of events (text deltas, tool calls,
  state snapshots and JSON-Patch deltas), bidirectional, with interrupts
  for human-in-the-loop decisions. It is transport-shaped, not
  UI-shaped: a terminal, a mobile app, or a chat platform can all be
  clients.
- **A2UI** is a declarative UI language. The agent names components from
  a catalog the client already knows, binds them to data, and the client
  renders them with its own design system. Because the agent never ships
  markup or script, this is the safe form of "generative UI".
- **Open-JSON-UI** (OpenAI) sits in the same category as A2UI, tied to
  OpenAI's response schemas.
- **MCP Apps** are the tool-level variant: a tool result carries a
  sandboxed HTML application rather than a component tree. A2UI can be
  delivered over MCP and over A2A as well, not only over AG-UI.

So the layers stack: *what to render* (A2UI) over *how it travels*
(AG-UI) over *where the data came from* (MCP).

Code intelligence is its own layer
----------------------------------

LSP is often filed under "tools the agent uses", which is only half
right: it is an editor↔language-server protocol, and agents borrow it
(the usual trick is running diagnostics after an edit). Two neighbours
belong in the same picture:

- **SCIP** (Sourcegraph Code Intelligence Protocol) is a language-agnostic
  *index* format — definitions, references, symbols — meant to be built
  once and queried cheaply, rather than computed per request.
- **grove** is the tree-sitter CLI that shaped the "structural sight"
  idea in ``ROADMAP.md``: ``outline`` / ``symbols`` / ``source-by-symbol``
  / ``callers`` / ``check``, plus ``tap`` for audit traces and
  ``grove-explore`` for file-location delegation. It covered 27 languages
  when the note was written; **Elixir was not one of them**, and its
  answers are name-based rather than semantic.

That gap is why the roadmap's plan is Elixir-native rather than a grove
wrapper: ``Code.string_to_quoted`` + ``Code.Typespec`` + the compile
tracer give semantic answers where a tree-sitter index can only match
names. Exported as one MCP server, those queries would be a tool like any
other — which is also why the roadmap files the MCP server edition under
phase 7.

MCP and LSP **compose** rather than compete: an MCP server can wrap a
language server and expose its capabilities as tools, which is how an
agent gets IDE-grade code intelligence without being an editor.
`mcp-language-server <https://github.com/isaacphi/mcp-language-server>`_,
`lsp-mcp <https://github.com/Tritlo/lsp-mcp>`_ and
`Serena <https://github.com/oraios/serena>`_ (LSP clients for 30+
languages behind one MCP server) all do this. The seam costs something,
though: the bridge owns the document lifecycle, so it sees files on disk
and not an editor's unsaved buffers; LSP's *pushed* diagnostics become an
on-demand query; and the language server is a second heavy process (the
Elixir ones run a JVM). Reaching LSP *through* MCP is therefore the cheap
route — it needs no LSP client of our own.

What this harness speaks, plans, and skips
------------------------------------------

.. list-table::
   :header-rows: 1
   :widths: 16 14 70

   * - Protocol
     - Status
     - Why
   * - ACP
     - watch
     - The door for "Zed (or any ACP client) drives a session". The
       harness would implement the *agent* side, so its session, permission
       gate and sandbox stay authoritative; ACP's permission requests map
       onto the gate. Not implemented, and not needed for terminal use —
       the TUI is a driver of its own (ADR 004).
   * - MCP
     - planned
     - Phase 7 names an MCP client so external tools arrive through the
       permission system like any other tool, and an MCP server as the
       edition for the code-intelligence queries. MCP *elicitation* is also
       the standard shape of the harness's ``question`` tool.
   * - A2A
     - no
     - The ``task`` subagent is deliberately in-process: isolated child
       context, summary-only return, depth 1 (ADR 017/018). A2A becomes
       interesting only if subagents leave the process, which is not
       planned.
   * - LSP / DAP
     - no
     - The compile/test loop covers the common cases; the roadmap rates
       LSP "unlikely" and DAP is not on it. If LSP-grade answers are ever
       wanted, the cheap route is an MCP bridge (above), not an LSP client.
       Debugging today is ``shell`` plus ``mix test``.
   * - AG-UI / A2UI
     - no
     - The TUI renders itself on ``ex_termbox``; there is no web or mobile
       front end to connect. The one dialog surface — the ``question``
       wizard (ADR 027) — is exactly the shape A2UI or MCP elicitation
       standardize, so this is a choice to revisit if a second front end
       ever appears, not a limitation.
   * - AP2 / UCP /
       Agentic Commerce
     - out of scope
     - The harness does not spend money.
   * - ANP / AGNTCY
     - watch
     - Discovery and directory layers above A2A; relevant only to a
       multi-agent deployment, not to a single local session.

Two conventions look like protocols but are not: ``AGENTS.md`` (a file
the agent reads) and ``llms.txt`` (a site index for models). They carry
no messages and have no wire format.

Where the facts live
--------------------

- The "structural sight" entry and the opencode tool-parity table:
  ``ROADMAP.md``, section "Later (one day)". The fuller wording — grove's
  27 languages, ``tap``, ``grove-explore``, the ``is-grep-enough``
  benchmark — was trimmed on 2026-10-04; it survives in the history of
  ``ROADMAP.md`` (``git show f3b887f -- ROADMAP.md``).
- Tool policy and the reason MCP tools will not get a bypass:
  :doc:`about-tools` and ADR 010.
- The reason a terminal needs none of the UI layer: ADR 004 and
  :doc:`stack`.
- The question wizard that would be the first candidate for a standard
  dialog payload: ADR 027.

Primary sources: `Agent Client Protocol <https://agentclientprotocol.com/>`_,
`Model Context Protocol <https://modelcontextprotocol.io/>`_,
`A2A <https://a2a-protocol.org/>`_,
`AG-UI <https://docs.ag-ui.com/>`_,
`A2UI <https://a2ui.org/>`_,
`LSP <https://microsoft.github.io/language-server-protocol/>`_,
`DAP <https://microsoft.github.io/debug-adapter-protocol/>`_.

Re-check this page when ACP's remote support lands, when A2UI leaves
v1.0-candidate status, or when MCP Apps and A2UI settle how tool UI is
split between them.
