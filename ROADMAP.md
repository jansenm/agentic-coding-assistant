<!--
SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
SPDX-License-Identifier: MPL-2.0
-->

# Roadmap

An agentic coding assistant for Elixir/BEAM — trustworthy, lightweight,
compilable from source, terminal-first.

Status: **phase 1 started** — the Mix app `coding_agent` is scaffolded
(single app, supervision tree, req_llm wired). The architecture and
technology decisions are recorded as ADRs in
[docs/source/decisions/](docs/source/decisions/index.rst);
the readable stack overview lives in
[docs/source/explanation/stack.rst](docs/source/explanation/stack.rst).

## Decided

| Area                     | Decision                                           | ADR                                                     |
|--------------------------|----------------------------------------------------|---------------------------------------------------------|
| Runtime                  | Elixir/OTP, pure-Elixir dependency tree            | [002](docs/source/decisions/002-elixir-beam.rst)        |
| Agent core               | Hand-rolled loop, no agent framework               | [003](docs/source/decisions/003-agent-framework.rst)    |
| LLM client               | `req_llm`                                          | [005](docs/source/decisions/005-llm-client.rst)         |
| Terminal UI              | Hand-rolled on `ex_termbox`                        | [004](docs/source/decisions/004-terminal-framework.rst) |
| Terminal input           | Readline-style editing component on termbox events | [006](docs/source/decisions/006-terminal-input.rst)     |
| Multi-agent target model | Specialist/repository matrix                       | [007](docs/source/decisions/007-agent-matrix.rst)       |

## Phases

1. **Core single-agent loop** ✅ — session process, streaming turns,
   multi-turn chat (`mix agent` / `mix agent --chat`), ollama provider,
   tool-call *detection*. Model config, error paths.
2. **Tool subsystem** — scope-aware file tools and shell execution with
   a permission gate (HITL: pause, approve/edit/reject, resume).

   Slices, each ending in something runnable:

   - **2a. Read-only tools** — tool spec as plain data (name, params,
     scope, callback) in a registry; `list_dir` + `read_file` scoped to
     the session working directory with path-escape checks; loop wiring
     (model requests tool → executed → result appended → loop
     continues). *Runnable:* the agent answers "how many .ex files are
     in lib and how big are they?" using real tool calls. Read-only
     tools need no gate (allow-by-policy for read-only — one recorded
     paragraph in ADR 010).
   - **2b. Permission gate** — *includes* designing the format(s) tools
     and permissions are defined in; precedent: this phase introduces
     exactly one file format and its loader (see below). Permission
     table as data `(tool, path-pattern) → :allow | :ask | :deny`,
     loaded from application config + a project-level file; HITL pause
     on `:ask` with the UI-agnostic decision API
     (`:approve | :edit(args) | :reject`). Format choices (TOML vs.
     alternatives, load order, elevation limits, file naming vs.
     AGENTS.md confusion) are decided in ADR 010 at slice start.
     AGENTS.md stays the standard instruction layer and is consumed
     as-is (no competing prose format); it steers behavior *within*
     policy limits but can never change them (non-elevation applies to
     prompts too). Agent definitions ride in the same structured
     format later (ADR 007); 2b ships only tool enablement + the
     permission table.
     *Runnable:* `write_file` demoed twice — auto-allowed by pattern,
     paused for approval when not matched — and the difference is
     driven by editing the permission file, not by recompiling.
   - **2c. Shell execution** — the dangerous one, last; command
     allow-list vs. always-ask is an ADR 010 decision. Output capture,
     timeout, working-directory scoping. *Runnable:* the agent runs the
     test suite and summarizes failures.
3. **Sessions & memory** — persistence, resume, compaction of the
   working context, dual view (LLM history vs. display transcript).
4. **Terminal experience** — transcript pane, input line (ADR 006),
   approval flows, session switcher.
5. **Multi-agent** — agent definitions as data, orchestration roles
   (plan/execute/analyze), the specialist/repository matrix (ADR 007).
   Cross-repo change atomicity gets its own ADR first.
6. **Extensibility** — skills as per-specialist knowledge packages;
   ACP/MCP client so external tools arrive through the permission
   system like any other tool.

## Ground rules

- Every dependency addition worth debating gets an ADR (dependency count
  is a security metric — ADR 002).
- Architecture first, implementation after understanding; ADR 003-style
  constraint records keep revisiting cheap.
- Documentation lives in `docs/` (Diátaxis structure, ADR log of every
  decision); how to build them: `docs/source/howtos/build-docs.rst`.
- Phases are broken into slices with a *runnable* acceptance demo; a
  slice is done when it can be demonstrated, not when it is designed.