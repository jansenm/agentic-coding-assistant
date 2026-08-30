<!--
SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
SPDX-License-Identifier: MPL-2.0
-->

# Roadmap

An agentic coding assistant for Elixir/BEAM — trustworthy, lightweight,
compilable from source, terminal-first.

Status: **phase 2 in progress** — the Mix app `coding_agent` is live
(single app, supervision tree, req_llm wired): streaming agent loop,
multi-turn chat, scoped file tools, permission gate (HITL). The
architecture and technology decisions are recorded as ADRs in
[docs/source/decisions/](docs/source/decisions/index.rst);
the readable stack overview lives in
[docs/source/explanation/stack.rst](docs/source/explanation/stack.rst).

## Goal: dogfooding

The first real test of the tool is **developing this repository *in*
this tool**, with opencode idle. That milestone defines the exit
criteria for the tool phase — no feature work beyond it until it is
reached.

Meeting these criteria is the critical path; everything else is
post-milestone:

- Tools: `read_file`, `list_dir`, `write_file` (✅), `shell`
  (non-negotiable: `mix test`, `mix format`, `git commit`),
  `grep` + `glob` (we search constantly; without them the round
  budget dies), `edit` (survivable without via `write_file`, but
  expensive on real refactors).
- Loop: multi-turn chat with streaming (✅); model tool-calling
  reliability and context management (compaction) are the real
  unknowns — dogfooding is how we find out.
- Safety: shipping `agent-permissions.toml` hardened from day one
  (shell always-ask, `git` behind the gate), with git as the undo
  mechanism.

Explicitly *not* needed for the milestone: webfetch, websearch, lsp,
skills execution, todowrite, question — see "Later".

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
2. **Tool subsystem** — scope-aware file tools and shell execution
   with a permission gate (HITL: pause, approve/edit/reject, resume).

   Slices:

   - **2a. Read-only tools** ✅ — registry, `list_dir` + `read_file`
     with path-escape checks, full ReAct loop (verified live: correct
     recursive file count).
   - **2b. Permission gate** ✅ — `agent-permissions.toml`
     (restrictive-wins layered merge, fail-closed), gate checkpoint with
     `:allow | :ask | :deny`, `decide/3` API (`:approve | :edit |
     :reject`), `write_file` behind the gate, stdin approval stub.
     Acceptance demo passed → ADR 010 Accepted.
   - **2c. Shell execution** — command semantics per ADR 010 (always-
     ask in v1). Output capture (stdout+stderr, head+tail keep on
     truncation — *tail* is what matters for test output), exit code,
     timeout (model-supplied, hard-capped by us), cwd pinned to scope
     root, no path containment in v1 (that's *why* it is always-ask).
     *Runnable:* the agent runs the test suite and summarizes failures.
   - **2d. grep + glob** — read-only tools, slot into existing
     containment (`read_only/1` + `in_scope?/2`), line-numbered
     matches, capped results. Pure Elixir, no ripgrep dependency.
     Without these, context economy on real repos is broken.
   - **2e. edit** — targeted string replacement (fail-closed on
     non-unique match), gated like `write_file`. Ends the era of
     whole-file rewrites for small changes.
3. **Dogfood milestone** — develop this repository inside the tool
   (see *Goal: dogfooding* above). Exercises model reliability and
   context management on our own workflow.
4. **Sessions & memory** — persistence, resume, compaction of the
   working context, dual view (LLM history vs. display transcript).
5. **Terminal experience** — transcript pane, input line (ADR 006),
   approval flows, session switcher.
6. **Multi-agent** — agent definitions as data, orchestration roles
   (plan/execute/analyze), the specialist/repository matrix (ADR 007).
   Cross-repo change atomicity gets its own ADR first.
7. **Extensibility** — skills as per-specialist knowledge packages;
   ACP/MCP client so external tools arrive through the permission
   system like any other tool.

## Later ("one day")

Not planned, not forgotten — recorded so re-evaluation is cheap:

| opencode tool | Ours | Note |
|---|---|---|
| `read` | `read_file` ✅ | parity (containment is *structural* here, not config-advised) |
| `write` | `write_file` ✅ | parity; ours always-gated (stricter, deliberate) |
| `bash` | `shell` (2c) | parity; ours always-ask in v1 vs their config-optional |
| `glob` | (2d) | slot into existing read-only containment |
| `grep` | (2d) | line-numbered, capped |
| `edit`/`apply_patch` | (2e) | fail-closed on non-unique match |
| `webfetch` | one day | gated-ask candidate; needs its own ADR (SSRF-ish concerns: redirects, file:// URLs) |
| `websearch` | one day | search-API dependency; low value for a coding agent |
| `lsp` | unlikely | language-server surface is huge; compile/test loop covers most agent needs |
| `skill` | ADR 007 territory | frontmatter loading documented in configuration-landscape; execution later |
| `todowrite` | one day | session scratchpad, pure state, cheap — after dogfood |
| `question` | **needs an ADR** | model-invoked stop-and-ask vs. harness-side gate; a loop concern, not a tool — do not hack it into the gate |

The structural difference to record when touching ADR 010 next:
opencode-style agents fail *open* on symlink escapes (their `read`
does textual path handling; permission rules are user-authored
policy), while our file tools fail *closed* (physical resolution +
scope, enforced with a guard suite that turns every known attack into
a permanent tripwire). Also note their `permission.read` frontmatter
granularity maps onto our tool table (`read` → `list_dir` + `read_file`).

## Ground rules

- Every dependency addition worth debating gets an ADR (dependency count
  is a security metric — ADR 002).
- Architecture first, implementation after understanding; ADR 003-style
  constraint records keep revisiting cheap.
- Documentation lives in `docs/` (Diátaxis structure, ADR log of every
  decision); how to build them: `docs/source/howtos/build-docs.rst`.
- Phases are broken into slices with a *runnable* acceptance demo; a
  slice is done when it can be demonstrated, not when it is designed.