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
2. **Tool subsystem** ✅ — scope-aware file tools and shell execution
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
   - **2c. Shell execution** ✅ — command semantics per ADR 010 (always-
     ask in v1). Output capture (stdout+stderr merged through /bin/sh,
     head+tail keep on truncation — *tail* is what matters for test
     output), exit code, timeout: model-supplied `timeout_secs` per
     call (default 300s = soft cap, hard cap 1800s — fits a 12-min
     Java integration suite; kill on expiry and return captured output
     + timeout note). Soft cap: above 300s the approval prompt shows
     the requested timeout so the user can edit via the gate's
     `:edit` decision; when shell allow-rules arrive later, soft-cap
     excess forces `:ask` even for allow-listed commands. Cwd pinned
     to scope root, no path containment in v1 (that's *why* it is
     always-ask). Port-based exec with kill on expiry; background
     runs parked in "Later".
     *Runnable:* `mix run demo/acceptance_2c.exs` (ask → approve →
     output back; soft-cap visible; edit respected). LLM round-trip
     demo (agent summarizes real failures) still to do live.
   - **2d. grep + glob** ✅ — read-only tools, slot into existing
     containment (`read_only/1` + `in_scope?/2`; dirs in walks are
     scope-checked too — the symlinked-dir lesson twice). Grep:
     line-numbered matches, cap 200, binary sniff, skip `_build`/
     `deps`/`.git`. Glob: pure-string matcher (Elixir 1.20 has no
     `Path.match/2`) in `Tools.Glob.glob_match?/2` — `**` spans
     segments, braces, per-segment `*`/`?` — cap 500. Live-verified:
     the agent greps `in_scope?` usage and counts 14 matches across 6
     files, exact.
   - **2e. edit** ✅ — targeted string replacement (fail-closed:
     refuses on 0 or 2+ matches with re-read/widen guidance), gated
     like `write_file`; empty old_string creates a file. Ends the era
     of whole-file rewrites for small changes. *Runnable:*
     `mix run demo/acceptance_2e.exs` (ambiguous -> refused; gate
     :edit widens the span -> applied; reject -> untouched).
     Live-verified: the model reads + edits its own file, gate asks,
     result confirmed.
3. **Dogfood milestone** — **conditionally met** (first real task:
   README rework, executed end-to-end in `mix agent --chat`, agent-
   initiated verification via shell, fact-checked result committed).
   Proven: the loop, all seven tools, gate round-trips, model
   research-before-write. Not yet proven: long sessions (context
   growth — no compaction), multi-turn work-in-progress, trust
   scaling. Those are exactly phase 4's territory, which becomes the
   critical path. Dogfood also surfaced 9+ interaction bugs, fixed
   along the way (hung receive, one-shot approval loop, 2-min decide
   timeout, write_file-shaped arg editing, silent reject-on-prose,
   grep/glob wrongly gated, paste-queue desync, stateless transcript
   framing) — the phase-5 TUI requirements list.
4. **Sessions & memory** ✅ — persistence, resume, compaction of the
   working context, project memory (AGENTS.md at session start).
   The dual display view is phase-5 TUI work.

   - **4a. Persistence & resume** ✅ — `Session.Store`:
     version-tagged `term_to_binary` snapshots under
     `~/.local/state/coding_agent/sessions/`, atomic write at every
     turn boundary; fail-closed load (corrupt/wrong-version errors,
     never half-states); running/error resume as idle, interrupted
     resumes with pending gate decisions intact. CLI: `mix agent
     --sessions`, `mix agent --resume <id>`. Live-verified: codeword
     given in one process answered correctly after `--resume`.
     Two live-found bugs fixed along the way: `[:safe]` atom
     rejection broke cross-process resume; stream errors crashed the
     session GenServer instead of failing the turn.
   - **4b. Compaction** ✅ — summarize-and-trim before each LLM call:
     80k-char trigger, last 6 messages kept verbatim, model-written
     summary replaces the old span, compacted state persists
     immediately; summary-call failure degrades (keeps full context),
     never errors. Lifecycle verbs shipped first per the storage
     principles: `--session-delete <id>`, `--session-prune <days>`,
     `--sessions` now prints file paths + sizes. Live-verified: a
     238k-char tool result compacted on the next call and the model
     still answered correctly from the summary.
   - **4c. Project memory** ✅ — `AGENTS.md` at the scope root is read
     at session start into the system prompt (64 KiB cap, truncated
     with a warning; missing = normal). Knowledge stays in the repo —
     versioned, greppable, editable with our own tools. Parent-dir
     walk and user-level fallback remain phase 5.
   - **4c. Project memory** ✅ — `AGENTS.md` at the scope root is read
     at session start into the system prompt (64 KiB cap, truncated
     with a warning; missing = normal). Knowledge stays in the repo —
     versioned, greppable, editable with our own tools. Parent-dir
     walk and user-level fallback remain phase 5.
5. **Terminal experience** — transcript pane, input line (ADR 006
   semantics on ADR 012 backend), approval flows, session switcher.
   The dogfood ledger is the requirements list (state line, approval
   widget with multiline editing, multi-line paste, streaming render,
   session switcher, resize/scrollback).

   - **5b. Input + approval flow** ✅ — input area (ex_ratatui
     Textarea) driven by the ADR 011 keymap via UI.Bridge: enter =
     newline, alt-enter = send, ctrl-enter = send (kitty hook),
     bracketed paste lands natively (the CLI paste-queue desync has no
     TUI counterpart). Approval dialog: pending gate calls render
     pretty-printed; y approves, n rejects (both updating the TUI from
     the session's decide reply); quit is a keymap binding (:q, honored
     on an empty buffer only — with text, q is a character).
     **Design correction after two live crashes**: the bridge started
     out atomizing EVERY keypress (to_existing_atom crashed on any
     letter the VM had not interned — "C", then "o"; tests passed by
     accident because test files intern their own atoms). Final shape
     is two-tier: special keys + letters the KEYMAP binds (read from
     the bindings, not hardcoded) become keymap events; everything
     else — the full UTF-8 range — is TEXT, forwarded raw to the
     textarea, never atomized. The atom vocabulary is bounded by the
     keymap, not by typing. 13 bridge tests incl. the whole UTF-8
     text tier (umlauts, emoji, CJK, uppercase).
     Also found live during 5b: the textarea NIF state is mutated in
     place (handle_key returns :ok, not a new ref) and the TUI attaches
     to the session's CURRENT status/pending on mount (a resumed/
     attached TUI shows the real gate state, not stale idle).
   - **5a. Foundation + state line** ✅ — ADR 012 (ex_ratatui
     backend, superseding the termbox amendment: the C build was
     broken (waf/python2-era) and the rust core is the battle-tested
     part: ratatui 48M downloads on crossterm 185M). UI.Tui driver
     app: alt-screen transcript + status line rendering live session
     events (deltas, status, tool executions, compaction notices),
     session resume support, `mix tui` entry. 4 headless-runtime
     tests (test_mode + event injection) — the discipline from
     ADR 011/012 holds: no terminal needed in CI.
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
| background shell runs | one day | the real escape hatch for very long jobs: tool returns "started, job id", agent polls / gets notified, user keeps working; needs session+TUI machinery (phases 3-4) — v1 answer is generous `timeout_secs` |
| runtime introspection (BEAM) | one day | the Elixir-native cousin of Tidewave's runtime tools (Dashbit; requires a hosted Phoenix app — not our path): eval-in-node (gated always-ask like shell), process/supervisor state, ETS inspection. Valuable once the agent debugs its own runtime; also a reason to keep an eye on ACP as the interop layer |
| `question` | **needs an ADR** | model-invoked stop-and-ask vs. harness-side gate; a loop concern, not a tool — do not hack it into the gate |
| code-intelligence queries (`outline` / `symbols` / `source-by-symbol` / `callers` / `check`) | one day | the "structural sight" idea (cf. grove + `is-grep-enough` benchmark, CGA): returns *answers*, never raw AST (AST as implementation detail only). For Elixir via `Code.string_to_quoted` + `Code.Typespec` + compile tracer — semantic-grade where tree-sitter tools (grove) are name-based only, and Elixir is missing from grove's 27 languages. Evidence says grep wins on simple lookups; structural pays off on trace/architecture tasks (2-3x fewer tokens). **Benchmark context quality first** (tokens, grounding, completeness), CGA/is-grep-enough style, before building the tier. `check` (post-edit syntax gate) folds naturally into 2e `edit`. LSP only if rename-references are ever demanded; an MCP *server* exporting these queries is the phase-7 interoperability edition |

Beyond tools — the trajectory after dogfooding, roughly:

1. **Get it running for dogfooding** (milestone above).
2. **Optimize it for dogfooding** — the loop learns this repo's workflow (compaction, the delegate-locator idea: a cheap local model hunts files in its own context and returns location lines only, grove-explore-style; audit traces like grove's `tap`).
3. **Then the owner's actual domain**: Java / Maven / Jenkins workspace motivation — multi-repo matrix (ADR 007), Maven POM comprehension, Jenkinsfile/Groovy tooling. All future; nothing here should block slices 2c-2e.

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