<!--
SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
SPDX-License-Identifier: MPL-2.0
-->

# Roadmap

An agentic coding assistant for Elixir/BEAM — trustworthy, lightweight,
compilable from source, terminal-first.

Status: **phase 6 in progress** — phases 1-2 (core loop, tool subsystem)
and 4 (sessions & memory) are done; phase 5 (terminal experience) shipped
5a-5c, 5f-5h, and the phase-6 agent work has started (definitions +
build/plan, ADR 017-019). The dogfood milestone was met and ADR 015 shell
confinement shipped — shell/git run allow-by-default inside the
bubblewrap profile, with network/git-write escalations prompting. The Mix
app `coding_agent` is live (single app, supervision tree, req_llm wired):
streaming agent loop, multi-turn chat, scoped file tools, permission gate
(HITL). The architecture and technology decisions are recorded as ADRs in
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
- Safety: shipping the project policy file hardened from day one
  (`.coding-agent/permissions.toml`, ADR 014; the legacy
  `agent-permissions.toml` at the scope root is still read) —
  shell always-ask, `git` behind the gate — with git as the undo
  mechanism.

Explicitly *not* needed for the milestone: webfetch, websearch, lsp,
skills execution, todowrite, question — see "Later". (Webfetch has
since shipped anyway, ADR 013 — dogfood showed doc work needed it.)

## Decided

| Area                     | Decision                                           | ADR                                                     |
|--------------------------|----------------------------------------------------|---------------------------------------------------------|
| Runtime                  | Elixir/OTP, pure-Elixir dependency tree            | [002](docs/source/decisions/002-elixir-beam.rst)        |
| Agent core               | Hand-rolled loop, no agent framework               | [003](docs/source/decisions/003-agent-framework.rst)    |
| LLM client               | `req_llm`                                          | [005](docs/source/decisions/005-llm-client.rst)         |
| Terminal UI              | Hand-rolled on `ex_ratatui` (supersedes `ex_termbox`) | [004](docs/source/decisions/004-terminal-framework.rst), [012](docs/source/decisions/012-tui-backend.rst) |
| Terminal input           | Readline-style editing component on ratatui events | [006](docs/source/decisions/006-terminal-input.rst), [012](docs/source/decisions/012-tui-backend.rst) |
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
   - **2b. Permission gate** ✅ — project policy file
     (restrictive-wins layered merge, fail-closed), gate checkpoint with
     `:allow | :ask | :deny`, `decide/2` API (`:approve | :edit |
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
   Proven: the loop, the then-seven tools, gate round-trips, model
   research-before-write. Not yet proven at the time: long sessions
   (context growth — no compaction), multi-turn work-in-progress, trust
   scaling. Those were phase 4's territory, now ✅ (persistence,
   resume, compaction, project memory); the remaining proof is sustained
   real-world use. Dogfood also surfaced 9+ interaction bugs, fixed
   along the way (hung receive, one-shot approval loop, 2-min decide
   timeout, write_file-shaped arg editing, silent reject-on-prose,
   grep/glob wrongly gated, paste-queue desync, stateless transcript
   framing) — the phase-5 TUI requirements list.
4. **Sessions & memory** ✅ — persistence, resume, compaction of the
   working context, project memory (AGENTS.md at session start; the
   parent-dir walk / user-level fallback of 4c are the phase-5
   remainder). The dual display view is phase-5 TUI work.

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
     80k-char trigger (superseded by 5f's absolute token trigger),
     last 6 messages kept verbatim, model-written
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
5. **Terminal experience** — transcript pane, input line (ADR 006
   semantics on ADR 012 backend), approval flows, session switcher ✅.
   The dogfood ledger is the requirements list (state line, approval
   widget with multiline editing, multi-line paste, streaming render,
   session switcher ✅, resize/scrollback).

   Slices are lettered by when they entered the plan; 5d/5e were never
   scoped. (ADR 011 labels the session-switcher binding "5d"; that
   shipped via the ctrl-x menu as 5h instead.)

   - **5a. Foundation + state line** ✅ — ADR 012 (ex_ratatui
     backend, superseding the termbox amendment: the C build was
     broken (waf/python2-era) and the rust core is the battle-tested
     part: ratatui 48M downloads on crossterm 185M). UI.Tui driver
     app: alt-screen transcript + status line rendering live session
     events (deltas, status, tool executions, compaction notices),
     session resume support, `mix tui` entry. 4 headless-runtime
     tests (test_mode + event injection) — the discipline from
     ADR 011/012 holds: no terminal needed in CI.
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
   - **5c. Rich transcript + scrolling** ✅ — block-stack transcript:
     tool calls collapsed by default ('t' -> ctrl-t after live
     feedback: t must stay typable; ALL single letters freed for text
     — approval keys live in the decision keymap only), dim
     diagnostics, Markdown answers (streaming deltas included), framed
     user messages. Viewport scrolling (measured heights! the
     estimate-drift lesson: markdown reflows — 21 estimated vs 16
     rendered on a real message; heights are now MEASURED via the
     headless buffer, cached in ETS) with mouse wheel + pgup/pgdn,
     clamped at both ends AT THE INPUT (the silent-inflation hang).
     Real terminal dims via mount capture + 500ms resize poller (the
      render-persistence illusion + no local Resize events — both found
      live). Status line carries live scroll diagnostics.
   - **5f. Compaction recalibrated (the opencode lesson)** ✅ —
     absolute token trigger (`compaction_trigger_tokens`, 180k
     default) replacing the 70%-of-window rule: the user's GLM
     sessions in opencode grew past 300k before compaction (big
     window, %-trigger) and per-turn cost scales with context size —
     quota burned "at unheard speeds". Sidebar now shows the
     configured model, reasoning effort, last-turn context size
     (+ % of window) and the compacts-at line; the session warns
     once at 80% of the trigger ("compaction at 180k will summarize
     older messages") so compaction is never a silent surprise.
   - **5g. Live-session polish pass** ✅ — from the first real
     working session (resume of tui-1730): reasoning deltas carry
     doubled newlines sent as SEPARATE delta events ('\n' + '\n') —
     squeezed on the ACCUMULATED string (per-delta squeezing destroys
     line breaks mid-stream); approval dialog capped to the reading
     measure, centered, %Clear{} behind it (the interior used to show
     the input through — and the debugging detour taught: a nested
     widget list from Enum.map silently stalls the whole render cycle,
     the bridge rejects it with 'expected {widget, Rect}, got: [..]');
     sidebar spans the full window; the input box grows while typing
     (opencode-style, floor 4 rows, cap 12) and re-derives pane dims
     on every keystroke; tool loop limit 12 -> 25 (a real task burned
     16 gate rounds and died; the agent blamed 'flaky parallel calls')
     with an honest error message — later raised to 100 per the 5f
     review lesson; webfetch (ADR 013) so doc work
     doesn't burn tool rounds; compaction recalibrated (5f).
   - **5h. Command menus, session switcher, esc-stop, markdown thinking**
     ✅ — `ctrl-x` command menu (fast-path letter within 1 s, timeout
     opens the popup; `switch session`, `toggle tool output`,
     `show keymaps`, `toggle sidebar`, `quit`), session switcher with
     keep-alive attach; double-esc to stop a running turn (armed esc,
     disarmed by any key/status change) on the `Core.Interrupt` ETS seam
     with hard stream cancel; reasoning rendered as Markdown like the
     answer (dim+italic base style, hard breaks preserve line structure);
     sidebar widened 24 -> 36 columns and toggleable (`ctrl-x p` / mount
     `sidebar: false`); answer text interleaves with thoughts in arrival
     order rather than collapsing below them.
6. **Multi-agent** — agent definitions as data, orchestration roles
   (plan/execute/analyze), the specialist/repository matrix (ADR 007).
   Cross-repo change atomicity gets its own ADR first.

   Slices:

   - **6a. Agent definitions + build/plan** ✅ — Markdown + YAML
     frontmatter (the agents standard, opencode/Claude-Code compatible),
     layered shipped < user < project, fail-closed with error
     aggregation (ADR 017). Authority is ADR 010 layer 4, finally
     populated: the definition's `permission` merges most-restrictive-wins
     and its tool set narrows by intersection, so a definition can never
     grant. `build` (full) and `plan` (edit/write/shell/git removed) ship
     as data. `yamerl` adopted directly (ADR 019, one dependency; the
     dangerous erlang_fun/atom node modules stay unregistered). UI (ADR
     018): sidebar shows two slots — `running` and `next` — with models;
     **Tab** switches the primary via `Session.set_agent/2`, recomputed
     from the session's base values so switching never compounds.
   - **6b. Subagent seam (`task` tool)** — the next slice: a child
     session with an isolated context, returning only a summary (ADR 007
     rule 3), depth 1 (subagents spawn no children), and per-subagent
     tabs in the UI (ADR 018). Escalations are part of the definition,
     never requested at runtime by a subagent (which has no human
     channel).
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
worktrees are today's answer but IDE support is poor (a second
worktree is seen as a separate project). Proposal: give each agent an
**overlay layer** over the same repo — its own writable delta, its own
`.git` delta, so it commits in isolation, publishes deliberately, and
the layer is thrown away. **Measured, and the core works:** two agents
each ran with their own `--overlay` for the worktree *and* their own
`--overlay` for `.git`; both committed independently
(`5e69be3`/`835bd9f`), the real repo stayed byte-identical. Publish
works as a deliberate step (bind `origin` rw for one invocation):
`d31edb4..07c189e main -> main`. Non-conflicting concurrent work
composes normally through `fetch` + `rebase` inside the layer, and a
conflict surfaces as a normal push rejection. The isolation boundary
is what makes publish explicit: with `--ro-bind / /` the remote is
invisible and unwritable, so an agent *cannot* push by accident — a
property plain worktrees do not give you. Open questions before this
is more than a note: layer lifetime/GC, whether `.git` truly needs an
overlay (vs. reusing the real object store read-only with refs in the
layer), IDE story (the whole reason to prefer this over worktrees),
and how the harness addresses per-agent layers. Note this is a
*different* use of overlays than ADR 015 rejected: there the overlay
was per-single-agent protection (superseded by "Git is the undo"); here
it is isolation *between* agents.

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
  approval work; ADR 011 separately labels an unbuilt session-switcher
  binding "5d", and that switcher has since shipped via the ctrl-x menu
  (5h), so treat "5d" as a loose label.
- `reasoning_effort` config knob surfaced in the sidebar (currently
  shows 'effort: default'; add `reasoning_effort: :high` to config
  when GLM effort is wanted).
- **shell tool drops commands — FIXED (03e3d62)**: root cause was the
  session, not Shell: the assistant tool-call message appended at the
  decide path hardcoded `arguments: "{}"`, erasing every prior call's
  args from the model's view → the model re-emitted empty-args calls →
  12-round loop of "required :command option not found". All 19 calls
  in tui-1730.session had `"{}"` persisted, even ones that executed.
  The Shell suspects below were all cleared by live repro: 1.2 MB
  output through the port intact (md5-verified), multiline commands
  fine, E2BIG handled. Dogfood note: watch for GLM *narrating* tool
  results without calling the tool (model-side; seen twice in probes).
- **thinking block grows stray newlines — FIXED (c4669c4)**: root
  cause was a measure/render mismatch: a trailing "\n" in the
  reasoning buffer measures as a phantom row (split on "\n" yields a
  trailing "" that wrapped_lines counts) while the Paragraph renders
  no extra row — the buffer ends in "\n" for most of the stream
  (line-by-line deltas), so the box kept growing blank rows. Fixed by
  trimming at the single render point (render_reasoning/1 in
  entry_widgets), never in the buffer (per-delta trim glues the next
  delta's first word when the separator streams as its own delta —
  test-locked).
- **Session list decodes the full context per file** (one day, perf):
  `Store.list/0` and `list_in/1` still `term_to_binary`-decode every
  whole session (context included) just to read id/model/mtime/scope.
  The double decode is gone (one `list_entries/0` pass), but a picker
  at 50+ sessions will feel it. Cheap fix: a small sidecar/header
  (id/model/mtime/scope written at save time, or a light summary
  element in the versioned tuple). Not correctness — defer until a
  picker actually lags.

| opencode tool | Ours | Note |
|---|---|---|
| `read` | `read_file` ✅ | parity (containment is *structural* here, not config-advised) |
| `write` | `write_file` ✅ | parity; allow-by-default since the 2026-09-15 ADR 010 amendment (contained + reviewable via the VCS diff); an out-of-scope path is refused by containment, not prompted |
| `bash` | `shell` ✅ (2c) | parity; ours always-ask in v1 vs their config-optional |
| `glob` | `glob` ✅ (2d) | slot into existing read-only containment |
| `grep` | `grep` ✅ (2d) | line-numbered, capped |
| `edit`/`apply_patch` | `edit` ✅ (2e) | fail-closed on non-unique match |
| `webfetch` | `webfetch` ✅ | ADR 013: always-ask, scheme allowlist, SSRF private-net block (re-checked per redirect hop), 128 KiB cap; de-tagged text (markdown conversion one day) |
| `websearch` | one day | search-API dependency; low value for a coding agent |
| `lsp` | unlikely | language-server surface is huge; compile/test loop covers most agent needs |
| `skill` | ADR 007 territory | frontmatter loading documented in configuration-landscape; execution later |
| `task` (subagent) | slice 6b | defined in ADR 017/018: isolated child context, summary-only return, depth 1, per-subagent UI tabs. Not built yet |
| `todowrite` | one day | session scratchpad, pure state, cheap — after dogfood |
| background shell runs | one day | the real escape hatch for very long jobs: tool returns "started, job id", agent polls / gets notified, user keeps working; needs session+TUI machinery (phases 3-4) — v1 answer is generous `timeout_secs` |
| mid-tool hard cancel | one day | `Core.Interrupt` stops a running turn between tools/at loop boundaries, but a single long `shell` still runs to its timeout (up to 1800 s). Needs `Shell` to expose a registered port-kill handle (same `Interrupt.register/2` seam) so esc kills the in-flight command |
| runtime introspection (BEAM) | one day | the Elixir-native cousin of Tidewave's runtime tools (Dashbit; requires a hosted Phoenix app — not our path): eval-in-node (gated always-ask like shell), process/supervisor state, ETS inspection. Valuable once the agent debugs its own runtime; also a reason to keep an eye on ACP as the interop layer |
| `question` | **needs an ADR** | model-invoked stop-and-ask vs. harness-side gate; a loop concern, not a tool — do not hack it into the gate |
| code-intelligence queries (`outline` / `symbols` / `source-by-symbol` / `callers` / `check`) | one day | the "structural sight" idea (cf. grove + `is-grep-enough` benchmark, CGA): returns *answers*, never raw AST (AST as implementation detail only). For Elixir via `Code.string_to_quoted` + `Code.Typespec` + compile tracer — semantic-grade where tree-sitter tools (grove) are name-based only, and Elixir is missing from grove's 27 languages. Evidence says grep wins on simple lookups; structural pays off on trace/architecture tasks (2-3x fewer tokens). **Benchmark context quality first** (tokens, grounding, completeness), CGA/is-grep-enough style, before building the tier. `check` (post-edit syntax gate) folds naturally into 2e `edit`. LSP only if rename-references are ever demanded; an MCP *server* exporting these queries is the phase-7 interoperability edition |

Beyond tools — the trajectory after dogfooding, roughly:

1. **Get it running for dogfooding** (milestone above).
2. **Optimize it for dogfooding** — the loop learns this repo's workflow (compaction, the delegate-locator idea: a cheap local model hunts files in its own context and returns location lines only, grove-explore-style; audit traces like grove's `tap`).
3. **Then the owner's actual domain**: Java / Maven / Jenkins workspace motivation — multi-repo matrix (ADR 007), Maven POM comprehension, Jenkinsfile/Groovy tooling. All future; nothing here blocks the shipped tools (2c-2e are done).

The structural difference to record when touching ADR 010 next:
opencode-style agents fail *open* on symlink escapes (their `read`
does textual path handling; permission rules are user-authored
policy), while our file tools fail *closed* (physical resolution +
scope, enforced with a guard suite that turns every known attack into
a permanent tripwire). Also note their `permission.read` frontmatter
granularity maps onto our tool table (`read` → `list_dir` + `read_file`).

**Protected-path class for the allow-by-default write tools.** Since
the 2026-09-15 amendment, `edit`/`write_file` auto-run anywhere in the
scope — including paths where a write is effectively invisible to the
review argument: `.git/*` (rewriting refs or hooks bypasses the VCS
reviewability argument itself), `AGENTS.md` / `.coding-agent/*`
(agent instructions and the project policy layer — a write there is
self-modification of the harness's own steering, and `.gitignore`d
content is not in any diff to review), `.env*` (secrets). Sketch:
a built-in `@ask_class` of path patterns checked before the class
default — same matching dialect, most-restrictive-wins as usual,
still overridable per layer; the check lives next to
`default_for/1` in `CodingAgent.Core.Permissions`. Until then
the manual equivalent is a repo-side policy file:

```toml
# .coding-agent/permissions.toml
[permissions.write_file]
".git/**" = "ask"
"AGENTS.md" = "ask"
".env*" = "ask"
```

**The y-fatigue countermeasure that SHIPPED (2026-09-15, ADR 010
amendment 2)** went the opposite direction of this sketch: not a
protected-path *ask*-class but a shell command **deny-list with
steering** — a shell call whose leading program duplicates a native
tool (grep/rg/ag/ack/sg in v1) is denied before the policy lookup with
"please use the grep tool", costing the user zero keystrokes and
steering the model to the allow-by-policy native tool in the same
round. Deliberately shallow (first word, basename, wrappers/env
looked behind; pipes and `git grep` pass through to the gate) and
honest about scope: prompt hygiene, not containment. Live evidence
drove the direction: nearly every remaining `y` was a grep-shaped
shell duplicate, and a user trained to rubber-stamp prompts is the
real security loss. `sed -n`/`cat`/`ls` are one-line follow-ups (each
needs its collision check first). See ADR 010 amendment 2 +
`Shell.blacklisted?/1`.

## Ground rules

- Every dependency addition worth debating gets an ADR (dependency count
  is a security metric — ADR 002).
- Architecture first, implementation after understanding; ADR 003-style
  constraint records keep revisiting cheap.
- Documentation lives in `docs/` (Diátaxis structure, ADR log of every
  decision); how to build them: `docs/source/howtos/build-docs.rst`.
- Phases are broken into slices with a *runnable* acceptance demo; a
  slice is done when it can be demonstrated, not when it is designed.