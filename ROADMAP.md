<!--
SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
SPDX-License-Identifier: MPL-2.0
-->

# Roadmap

An agentic coding assistant for Elixir/BEAM — trustworthy, lightweight,
compilable from source, terminal-first.

Status: **phase 6 in progress**. Phases 1–5 are done; the agent work has
started (definitions + build/plan, ADR 017–019), the subagent seam and tabs
have shipped (6a/6b, ADR 017/018), and **6c (the specialist matrix)** plus
**phase 7 (extensibility)** are open. The dogfood milestone was met. The
architecture and technology decisions are recorded as ADRs in
[docs/source/decisions/](docs/source/decisions/index.rst); the readable
stack overview lives in
[docs/source/explanation/stack.rst](docs/source/explanation/stack.rst).

This file is the **long-term plan**: the phases and the forward-looking
ideas under "Later". Finished slices fall out — their commits and ADRs are
the record. The short-term backlog is `TODO.md`; open review findings and
harness feedback are in `review.md`.

## Goal: dogfooding

The first real test of the tool is **developing this repository *in*
this tool**, with opencode idle. That milestone defines the exit
criteria for the tool phase — no feature work beyond it until it is
reached.

Meeting these criteria is the critical path; everything else is
post-milestone:

- Tools: `read_file`, `list_dir`, `write_file`, `shell`
  (non-negotiable: `mix test`, `mix format`, `git commit`),
  `grep` + `glob`, `edit`.
- Loop: multi-turn chat with streaming; model tool-calling
  reliability and context management (compaction) — the real unknowns,
  which dogfooding is how we find out.
- Safety: the project policy file hardened from day one
  (`.coding-agent/permissions.toml`, ADR 014); a confining sandbox is
  required (ADR 030), shell/git run allow-by-default inside the profile
  unless policy says otherwise, with git as the undo mechanism.

Explicitly *not* needed for the milestone: webfetch, websearch, lsp,
skills execution, todowrite, question — see "Later". (Webfetch, question
and todowrite have since shipped anyway; dogfood showed the need.)

## Decided

| Area                     | Decision                                           | ADR                                                     |
|--------------------------|----------------------------------------------------|---------------------------------------------------------|
| Runtime                  | Elixir/OTP, pure-Elixir dependency tree            | [002](docs/source/decisions/002-elixir-beam.rst)        |
| Agent core               | Hand-rolled loop, no agent framework               | [003](docs/source/decisions/003-agent-framework.rst)    |
| LLM client               | `req_llm`                                          | [005](docs/source/decisions/005-llm-client.rst)         |
| Terminal UI              | Hand-rolled on `ex_ratatui` (supersedes `ex_termbox`) | [004](docs/source/decisions/004-terminal-framework.rst), [012](docs/source/decisions/012-tui-backend.rst) |
| Terminal input           | Readline-style editing component on ratatui events | [006](docs/source/decisions/006-terminal-input.rst), [012](docs/source/decisions/012-tui-backend.rst) |
| Multi-agent target model | Specialist/repository matrix                       | [007](docs/source/decisions/007-agent-matrix.rst)       |

## Product thesis: confinement as the differentiator (recorded 2026-09-19)

Bubblewrap should be treated as a **product core**, not just a safety
mechanism — the thing that makes this harness distinct. Sandboxing itself
is not unique (Codex CLI has Seatbelt/Landlock, OpenHands/Devin have
containers), so the claim must be precise. What is rare is the
**combination** we already half-have:

- **per tool call**, not per session/container — no image build, no long
  boot, the sandbox is a property of each invocation;
- **declarative mount schema** (`rw` / `ro` / `hide`) rather than
  imperative flags — the policy is data, most-restrictive-wins;
- **fail-safe**: declarations only ever *narrow* access; where bwrap
  cannot run there is no session at all (ADR 030) — the tool refuses
  rather than degrading to an unconfined mode;
- **approval gates visible in the UI** instead of silent isolation.

The power is the **semantics above the namespace**: say declaratively
"this tool class may do exactly this" and have the runtime enforce it.
Two things would turn "nice" into a genuine differentiator:

1. **Traceability** — for every call, show *which* confinement applied
   (not merely that the tool ran). The mount profile is already data, so
   surfacing the effective profile is a rendering problem, not new law.
2. **User-extensible profiles/policy** — users author confinement the way
   they author permissions, without needing to know bwrap flags.

The session-scratch question this once raised is resolved (ADR 022:
per-session host scratch bound over `/tmp`). The multi-agent overlay work
below and this thesis are the same problem viewed from different ends.

## Phases

Completed phases are summarized to one line each; the detail is in the
ADRs and commits.

1. **Core single-agent loop** ✅ — session process, streaming turns,
   multi-turn chat. The CLI (`mix agent`) was retired 2026-09-20; the TUI
   is the only surface and every verb lives in `mix tui`.
2. **Tool subsystem** ✅ — scope-aware file tools and shell execution
   with a permission gate (HITL: pause, approve/edit/reject, resume).
   Slices 2a–2e: read-only tools, the permission gate (ADR 010), shell
   execution, `grep`+`glob` through the confined process path with the
   reference dialect as the answer (ADR 016 amendment; fallback retired,
   ADR 030), and `edit` (fail-closed on non-unique match). Details in
   ADR 010/016/030.
3. **Dogfood milestone** ✅ — the first real task was executed end-to-end
   in the tool with agent-initiated verification. Dogfood also surfaced
   the phase-5 TUI requirements (the interaction bugs it found are fixed).
4. **Sessions & memory** ✅ — persistence/resume (ADR 020), compaction
   (now ADR 037: window-relative soft/hard limits), project memory
   (`AGENTS.md` at the scope root; ADR 024). Details in the ADRs.
5. **Terminal experience** ✅ — transcript pane, input line, approval
   flows, session switcher. Slices 5a (foundation + state line, ADR 012),
   5b (input + approval), 5c (rich transcript + scrolling), 5f
   (compaction recalibrated, superseded by ADR 037), 5g (live-session
   polish), 5h (command menus, session switcher, esc-stop, markdown
   thinking). The live band and the sidebar redesign are ADR 018.
6. **Multi-agent** — agent definitions as data, orchestration roles
   (plan/execute/analyze), the specialist/repository matrix (ADR 007).
   Cross-repo change atomicity gets its own ADR first.

   - **6a. Agent definitions + build/plan** ✅ — Markdown + YAML
     frontmatter, layered shipped < user < project, fail-closed with
     error aggregation (ADR 017); the definition's `permission` merges
     most-restrictive-wins and its tool set narrows by intersection. `build`
     and `plan` ship as data (ADR 019 for `yamerl`).
   - **6b. Subagent seam (`task` tool) + tabs** ✅ — isolated child
     session, summary-only return, depth 1 (ADR 017/018); per-child tabs,
     a parallel cap, and esc forwarding (ADR 018 Amendment (ii)).
     Reachable-out-of-the-box since the built-in `explore` and the
     `subagent_model` knob (ADR 017 Amendment + ADR 042).
   - **6c. Matrix / orchestration** — vertical and horizontal
     specialists, cross-repo atomicity (needs its own ADR).
7. **Extensibility** — skills as per-specialist knowledge packages;
   ACP/MCP client so external tools arrive through the permission
   system like any other tool.

## Later ("one day")

Not planned, not forgotten — recorded so re-evaluation is cheap:

**bwrap layers as agent isolation** (distant future; evaluated
2026-09-17). The multi-agent problem: Agent 1 implements a feature
while Agent 2 reviews, and they collide on the working tree. Git
worktrees are today's answer but IDE support is poor. Proposal: give each
agent an **overlay layer** over the same repo — its own writable delta, its
own `.git` delta, so it commits in isolation, publishes deliberately, and
the layer is thrown away. **Measured, and the core works:** two agents each
ran with their own `--overlay` for the worktree *and* `.git`; both
committed independently, the real repo stayed byte-identical. Publish is a
deliberate step (bind `origin` rw for one invocation); a conflict surfaces
as a normal push rejection. The isolation boundary is what makes publish
explicit: with `--ro-bind / /` the remote is invisible and unwritable, so
an agent *cannot* push by accident — a property plain worktrees do not give
you. Open questions before this is more than a note: layer lifetime/GC,
whether `.git` truly needs an overlay (vs. reusing the real object store
read-only with refs in the layer), the IDE story, and how the harness
addresses per-agent layers. This is a *different* use of overlays than ADR
015 rejected: there the overlay was per-single-agent protection
(superseded by "Git is the undo"); here it is isolation *between* agents.

**Ticket / coordination store** (idea recorded 2026-09-19; not planned).
Multi-agent work (implementer + reviewer) currently coordinates through
Markdown documents that both sides edit: no stable identifiers, no status
field, no comment history, and a "moving target" when two agents touch one
file. The idea is deliberately small — *not* JIRA/Mantis: one central place
where agents record and coordinate work:

- **record** a TODO / FINDING (title, body, optional source ref like
  file:line or commit);
- **status** (`open` / `in_progress` / `done` / `wontfix` / `duplicate`),
  so "B2 done" is a state transition rather than a hand edit of prose;
- **comments**, to keep the history and let agents exchange context on one
  item instead of forking a document.

Storage: sits naturally in the same database direction as ADR 020 (session
storage) — a coordination database, likely one per store, with the same
verbs-first rule. A ticket should be able to `relate` to a session and to a
review finding. **Prerequisite is the R0 instinct from ADR 020**: ship the
verbs, keep the engine simple. Do not build this until the Markdown backlog
actually hurts.

**Reviewer in the same TUI, on a bwrap snapshot** (idea recorded
2026-09-19; future). Combine the bwrap-layer isolation above with the
ticket store: run the reviewer *as an agent inside the same TUI* as the
implementer, but give it a **read-write overlay snapshot** of the
implementer's working tree (bwrap `--overlay`), so it reviews a frozen,
reproducible state instead of the live tree both are editing. It writes
its findings as *tickets* (not a prose review document) that the
implementer consumes, which removes the shared-worktree collision
entirely. Both prerequisites, so it stays a future note. (For the review
to be reproducible it should pin an explicit ref/tree hash —
`git write-tree` gives that without committing the writer's work.)

TUI wish-list (user's own list, keyboard-first, from the live sessions):

- **Navigator**: Go To Questions / Go To Blocks popup (ctrl-g style,
  block-jump with pageup/pgdn, question -> blocks browser). Called
  the highest-value piece for keyboard work; placement math exists
  (block_at_row/2).
- **Frame-scrolling artifacts** (user will fix personally when
  learning the code — not a stopper): scrolling with the frames
  around user input / tool call boxes still glitches.
- **Approval-arg editing** in the TUI dialog (currently an on-screen
  'arrives later' notice; e is reserved). Leftover from the phase-5
  approval work.
- **`reasoning_effort` config knob surfaced in the sidebar** ✅ (ADR 029):
  `Config.reasoning_effort/1` resolves the layered value into req_llm's
  canonical atom, `wire_request/2` puts it on every request, and the
  sidebar renders the session's resolved value. Note: req_llm's Zai/GLM
  provider does not consume the option (it translates `:thinking` maps
  instead), so GLM effort remains provider-side; the OpenAI-compatible and
  Ollama paths honour it.
- **shell tool drops commands** ✅ (`03e3d62`) — root cause was the session
  hardcoding `arguments: "{}"` on the decide path, erasing every prior
  call's args from the model's view. Dogfood note: watch for GLM
  *narrating* tool results without calling the tool (model-side).
- **thinking block grows stray newlines** ✅ (`c4669c4`) — a measure/render
  mismatch: a trailing "\n" in the reasoning buffer measured as a phantom
  row. Fixed at the single render point, never in the buffer.
- **Session list decodes the full context per file** ✅ (ADR 020 slice 3a) —
  the listing reads metadata columns; the state BLOB is read only by
  `load/1`.

| opencode tool | Ours | Note |
|---|---|---|
| `read` | `read_file` ✅ | parity (the sandbox profile is the boundary; ADR 030) |
| `write` | `write_file` ✅ | parity; allow-by-default (ADR 010 amendment + ADR 030: confined `tee`) |
| `bash` | `shell` ✅ | parity; allow-by-default inside the profile since ADR 030 (escalations and explicit policy still ask) |
| `glob` | `glob` ✅ | confined `fd`, required since ADR 030 |
| `grep` | `grep` ✅ | line-numbered, capped |
| `edit`/`apply_patch` | `edit` ✅ | fail-closed on non-unique match |
| `webfetch` | `webfetch` ✅ | ADR 013: always-ask, scheme allowlist, SSRF private-net block (re-checked per redirect hop), 128 KiB cap; de-tagged text |
| `websearch` | one day | search-API dependency; low value for a coding agent |
| `lsp` | unlikely | language-server surface is huge; compile/test loop covers most agent needs |
| `skill` | ADR 007 territory | frontmatter loading documented in configuration-landscape; execution later |
| `task` (subagent) | `task` ✅ | isolated child context, summary-only return, depth 1 (ADR 017/018); built-in `explore` + `subagent_model` (ADR 042) |
| `todowrite` | ✅ (ADR 031) | the model's durable plan: full-list replace, session state, injected into every request, sidebar block |
| background shell runs | one day | the escape hatch for very long jobs: tool returns "started, job id", agent polls / gets notified. Needs session+TUI machinery; v1 answer is generous `timeout_secs` |
| mid-tool hard cancel | ✅ (ADR 043) | `Core.Exec` observes the stop flag while it waits and kills the in-flight OS process, so esc ends a hung `shell`/`grep`/`glob`/file op within one 250ms poll tick |
| runtime introspection (BEAM) | one day | the Elixir-native cousin of Tidewave's tools: eval-in-node (gated always-ask like shell), process/supervisor state, ETS inspection. Valuable once the agent debugs its own runtime |
| `question` | ✅ (ADR 027) | model-invoked stop-and-ask: the gate intercepts the call, the session parks, the TUI shows a wizard; a non-interactive driver gets an "unavailable" result |
| code-intelligence queries (`outline` / `symbols` / `source-by-symbol` / `callers` / `check`) | one day | "structural sight" (cf. grove + `is-grep-enough`): returns *answers*, never raw AST. For Elixir via `Code.string_to_quoted` + `Code.Typespec` + compile tracer — semantic-grade where tree-sitter tools are name-based. **Benchmark context quality first** before building the tier. LSP only if rename-references are demanded; an MCP *server* exporting these queries is the phase-7 edition |

Beyond tools — the trajectory after dogfooding, roughly:

1. **Get it running for dogfooding** (milestone above).
2. **Optimize it for dogfooding** — the loop learns this repo's workflow
   (compaction, the delegate-locator idea: a cheap local model hunts files
   in its own context and returns location lines only; audit traces).
3. **Then the owner's actual domain**: Java / Maven / Jenkins workspace
   motivation — multi-repo matrix (ADR 007), Maven POM comprehension,
   Jenkinsfile/Groovy tooling.

The structural difference to record when touching ADR 010 next:
opencode-style agents fail *open* on symlink escapes (textual path
handling; permission rules are user-authored policy), while our file tools
fail *closed* (physical resolution + scope, with a guard suite that turns
every known attack into a permanent tripwire). Their `permission.read`
frontmatter granularity maps onto our tool table (`read` → `list_dir` +
`read_file`).

**Protected-path class for the allow-by-default write tools** (open sketch).
`edit`/`write_file` auto-run anywhere in the scope — including paths where a
write is effectively invisible to review: `.git/*` (rewriting refs or hooks
bypasses the VCS reviewability argument itself), `AGENTS.md` /
`.coding-agent/*` (agent instructions and the project policy layer — a write
there is self-modification of the harness's own steering), `.env*` (secrets).
Sketch: a built-in `@ask_class` of path patterns checked before the class
default — same matching dialect, most-restrictive-wins, still overridable per
layer; the check lives next to `default_for/1` in
`CodingAgent.Core.Permissions`. Until then the manual equivalent is a
repo-side policy file:

```toml
# .coding-agent/permissions.toml
[permissions.write_file]
".git/**" = "ask"
"AGENTS.md" = "ask"
".env*" = "ask"
```

The y-fatigue countermeasure that **shipped** (2026-09-15, ADR 010 amendment
2) went the opposite direction: not a protected-path *ask*-class but a shell
command **deny-list with steering** — a shell call whose leading program
duplicates a native tool (grep/rg/ag/ack/sg) is denied before the policy
lookup with "please use the grep tool", costing zero keystrokes and steering
the model to the allow-by-policy native tool in the same round. Deliberately
shallow (first word, basename, wrappers/env looked behind; pipes and
`git grep` pass through) and honest about scope: prompt hygiene, not
containment. Live evidence drove it: nearly every remaining `y` was a
grep-shaped duplicate, and a user trained to rubber-stamp prompts is the
real security loss. `sed -n`/`cat`/`ls` are one-line follow-ups (each needs
its collision check first). See ADR 010 amendment 2 + `Shell.blacklisted?/1`.

## Ground rules

- Every dependency addition worth debating gets an ADR (dependency count
  is a security metric — ADR 002).
- Architecture first, implementation after understanding; ADR 003-style
  constraint records keep revisiting cheap.
- Documentation lives in `docs/` (Diátaxis structure, ADR log of every
  decision); how to build them: `docs/source/howtos/build-docs.rst`.
- Phases are broken into slices with a *runnable* acceptance demo; a
  slice is done when it can be demonstrated, not when it is designed.
