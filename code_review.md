# Code Review — responsibility factoring

Scope: `lib/` (11,969 lines across 46 modules). Focus: responsibilities that are
not cleanly factored out and are "sprinkled all over" the codebase. Line
references are to the tree as reviewed.

Verdict up front: the **design** is good — plain-data state, one execution
path for subprocesses (`Exec`), a real permission model, `Containment`, the
`Compaction`/`Compactor` split, `Interrupt`, `Bridge`/`Keymap`. The problem is
not bad architecture. It is that a handful of boundaries the codebase
*declares* are not enforced, and the same small decisions are re-made in two to
six places. That is normal for a codebase moving fast; none of it is
unrecoverable, but several items are latent bugs.

The framing rule is written down in `CodingAgent`'s moduledoc
(`lib/coding_agent.ex:6-9`):

- `CodingAgent.Core.*` — agent loop, HITL, memory, tools (no UI deps)
- `CodingAgent.UI.*` — terminal driver (no LLM deps)

Both halves of that rule are violated today.

---

## 1. The declared Core/UI boundary is broken

### 1.1 UI depends on LLM internals

The UI layer pattern-matches ReqLLM structs directly:

- `tui.ex:490-567` — `ReqLLM.Context.to_list`, `%ReqLLM.Message{}`,
  `%ReqLLM.Message.ContentPart{}`, `%ReqLLM.Error.API.Stream{}`.
- `tui.ex:2846` — `%ReqLLM.ToolCall{}`.
- `provider_health.ex:90` — calls `ReqLLM.generate_text` itself.

If ReqLLM changes shape, the view breaks. The UI should consume an internal
view model.

### 1.2 UI owns Core domain logic

Roughly 18 direct reaches into `Core.*`. The worst:

- `tui.ex:2570-2598` — `Agent.load(scope_root)` called from the view to derive
  the primary-agent list and each agent's model.
- `tui.ex:409-438` — session resume reconstructs `State` field-by-field, and
  must know to pass `base_policy` rather than `policy`, and to re-validate the
  agent name against current definitions. Every `State` field added forces a
  TUI edit.
- `tui.ex:2338-2341` — the `effective_model` precedence rule
  (`definition_model || session_model`) is re-encoded in the input footer,
  duplicating `Session.effective_model/1` (`session.ex:1407-1411`). The footer
  can display a different model than the turn actually uses.

### 1.3 Core/UI failure taxonomy split across two modules

- `tui.ex:589-643` — `classify_failure/1`, `classify_reason/1` and the
  `@local_markers` / `@provider_markers` tables.
- `provider_health.ex:104-127` — a **second**, independent classifier
  (`classify/1`, `humanize/1`) for the same domain question.

Two answers, drifting. This belongs in core (`Providers.Health` or
`Session.Failure`), consumed by both.

---

## 2. Configuration and disk access have no boundary

There is no config module. There are ten `Application.get_env` call sites and
eight `System.get_env` call sites spread across core, UI, CLI and sandbox:

```
Application.get_env:
  mix/tasks/tui.ex:107            :store_dir
  ui/tui.ex:2414                  :context_window_tokens
  ui/tui.ex:2431                  :reasoning_effort
  core/session.ex:70              :max_tool_rounds
  core/sandbox.ex:95              :sandbox
  core/session/store.ex:35        :store_dir
  core/user_config.ex:104         :model
  core/session/compactor.ex:298   :compaction_trigger_tokens
  core/session/compactor.ex:314   :compaction_wall_clock_ms
  core/session/compactor.ex:317   :compaction_inactivity_ms

System.get_env:
  application.ex:69, coding_agent.ex:24, user_config.ex:44,50,62,202,
  sandbox/mounts.ex:98, session/store.ex:41
```

Concrete consequences:

- **`Session.init` reads the same config three times through different paths**:
  `UserConfig.load(scope_root).config["providers"]` (`session.ex:293`),
  `Sandbox.Mounts.resolve(UserConfig.layers(scope_root, "config"))`
  (`session.ex:297`, which re-reads files `load/1` already merged), and
  `UserConfig.load(scope_root).permissions` (`session.ex:408`, though `load/1`
  already computed `.permissions` internally).
- **Defaults are duplicated** between `config/config.exs` and module
  attributes: `@default_max_tool_rounds` vs `config.exs:24`; compaction
  `180_000` in `compaction.ex:40` and `config.exs:18`; bwrap default in
  `sandbox.ex:85` and `config.exs:35`.
- **`CodingAgent.model/0`** (`coding_agent.ex:24`) bypasses
  `UserConfig.model/1` (`user_config.ex:103`), which is now dead code.
- **The "no model configured" message** is written out three times
  (`session.ex:198-201`, `mix/tasks/tui.ex:50-56`, `tui.ex:453-458`).
- **State-dir divergence**: `mix/tasks/tui.ex:107` derives a log dir from
  `:store_dir` with a different default and without the `/sessions` suffix that
  `Store.dir/0` uses (`store.ex:33-46`). Latent bug.
- **`UserConfig.project_dir_for_test/1`** (`user_config.ex:59`) is called by
  production code in `agent.ex:266`. A test-named seam on the production path.

A single `Config.snapshot(scope_root)` returning merged config + permissions +
mounts + providers + agents, read once, removes the bulk of this.

---

## 3. Duplicated decisions (each a place to drift)

| What | Copies |
|---|---|
| Tool-call normalization (`%ReqLLM.ToolCall{}` vs map + JSON) | `session.ex:1279-1295`, `mix/tasks/agent.ex:444-461`, `tui.ex:2843-2854` |
| Resume options (persisted field list) | `mix/tasks/agent.ex:198-218`, `tui.ex:409-438`, plus `Store.restore/1` |
| `check_scope` (single-path containment) | `Containment.check_scope!` exists (`containment.ex:49`); copied in `read_file.ex:37`, `write_file.ex:43`, `list_dir.ex:36` |
| Empty-mounts literal `%{rw: [], ro: [], hide: []}` | `state.ex:30`, `store.ex:208`, `store.ex:214`, `shell.ex:199`, `git.ex:138`, `session.ex:1331` |
| TOML load + error formatting | `user_config.ex:150-167`, `permissions.ex:178-211` |
| Timeout clamp + coerce | `Shell.effective_timeout` (`shell.ex:89`), `Git.effective_timeout` (`git.ex:55`) |
| Event broadcast dispatch | `session.ex:1652`, `:1658`, `:1664`, `compactor.ex:338`, `provider_health.ex:130` |
| Canonical tool-round exchange | `resolve_decisions` (`session.ex:580-648`) and `complete_round` (`session.ex:1094-1116`) |
| Path-expand idiom `Path.expand(path, Path.expand(scope.root))` | `read_file.ex:46`, `write_file.ex:52`, `list_dir.ex:45`, `edit.ex:71`, `edit.ex:88`, `grep.ex:304` |

The CLI comment at `agent.ex:441-443` explicitly says "normalize like the
session's `call_parts/1`" — the duplication is known.

---

## 4. Latent bugs hiding in the leaks

1. **Compaction ignores the agent's model and drops credentials.**
   `Compactor.summarize/2` (`compactor.ex:252`) calls
   `Request.build(state.model, state.provider_config)` and discards
   `_base_opts` before `ReqLLM.generate_text`. So an agent-pinned model
   (ADR 017) is ignored for summarization, and the `api_key` / `base_url` that
   `Request` exists to resolve is dropped. `call_llm` does it correctly with
   `effective_model(state)` (`session.ex:1415`). One seam, two behaviors.

2. **`Store.rename` drives a live GenServer.** `Store.notify_live/2`
   (`store.ex:272-277`) looks up `CodingAgent.Registry` and calls
   `Session.set_id`. Persistence depending on the process registry inverts the
   intended direction. If the live session is not registered, a renamed running
   session keeps saving under the old id.

3. **`Permissions.effective/4` is test-only.** Production uses
   `effective_decision/3` (`session.ex:1188-1203`), which re-implements the
   ADR 015 confinement exception and hardcodes `"shell"` / `"git"`. The
   documented public decision API (`permissions.ex:322`) no longer reflects
   production behavior.

4. **`grep` / `glob` bypass confinement.** They shell out with `System.cmd`
   (`grep.ex:138`, `glob.ex:82`) instead of the single `Port.open` +
   `Sandbox.wrap` path in `Exec` (`exec.ex:29-48`). `shell` and `git` are
   confined; these two are not, while the docs claim one execution path. They
   partially compensate with post-hoc path filtering.

5. **`grep` uses the process dictionary** for per-call state
   (`grep.ex:241-259`). Safe today (one process per callback) but
   non-reentrant by convention.

---

## 4b. Session storage — findings (not a defect list; a decision to make)

The store is deliberate and, for local single-user work, correct: one
session = one file = one `:erlang.term_to_binary({version, %State{}})`
blob, atomic tmp+rename, fail-closed load (`docs/source/explanation/
memory.rst`, "Session storage principles"). Measured on the dev machine:
19 sessions / 531 KB total; biggest 497 KB / 135 messages /
`last_input_tokens` 131k; `Store.load` ~1 ms, `Store.list` ~13 ms.

These are the pressure points to settle **before** the store grows, each
a candidate for its own ADR (principle 5: "revisit only with a new ADR"):

1. **Listing decodes every full state.** `list/0` / `list_in/1` call
   `load/1` per file (including `State.restore/1` healing) to read four
   summary fields each (`store.ex:205-245`). Cost scales with TOTAL
   bytes, not session count — at 500 sessions × ~500 KB this is the
   picker-mount frame again. A sidecar `meta` (or a fixed header read)
   would reduce listing to a stat/prefix read without changing the state
   format.

2. **Opaque binary ⇒ shape fragility.** Every `State`/nested-struct
   change needs healing in `State.restore/1`; that mechanism has already
   caused resume bugs (`base_policy`, `disabled`, `mounts`). A readable
   format (JSONL event log + `meta.json`) would be self-healing,
   `cat`/`grep`/diff-friendly, and gives `--export` for free — at the
   cost of custom encoders for the ReqLLM structs.

3. **Full rewrite per boundary.** Each `persist` re-serializes the whole
   context (`session.ex:1474`). Fine at 500 KB / multi-second turns, but
   there is no incremental path for 1M-token windows or more frequent
   writes.

4. **`binary_to_term` without `[:safe]`** (`store.ex:255`) is a conscious
   choice for user-local files (same trust domain as `.env`). It stops
   being safe the moment sessions are *shared or imported* — an import
   feature would turn a foreign session file into an atom-exhaustion /
   code-exec vector. **Resolved by scope, not by hardening**: export
   ships as a readable text/JSON transcript (no `binary_to_term`), and
   there is no import, so no foreign binary is ever decoded. A resumable
   import would need the safe-decoding work first (ADR 020, *Export*).

Retention is now explicit, not automatic: the picker offers prune-by-age
(`P`) and prune-by-size (`S`), each on the active source and each
confirmed. There is deliberately no automatic cap (ADR 020 `S6`: explicit
pruning is enough unless sessions can plausibly exhaust disk).

---

## 5. Two god modules

`session.ex` (1668) holds turn lifecycle, gate policy, tool execution,
prompt/AGENTS.md I/O, UTF-8 sanitization, usage accounting, persistence,
broadcasting, agent resolution. Its own moduledoc (`session.ex:30-39`) promises
a split (`Compactor` / `Request` / `Store`) that the code does not honor.

`tui.ex` (2881) holds bootstrap, picker, menu, keymap dispatch, event
reduction, rendering, provider health and persistence CRUD. Its internal module
boundaries are drawn with comments (`-- Terminal events`, `-- Menu mode`,
`-- Rendering`, ...) instead of `defmodule`s. The entire state map is defined
twice (`mount_picker` `tui.ex:141-195`, `mount_session` `tui.ex:287-381`).

---

## 6. What is genuinely clean (do not touch)

- `Interrupt` (`interrupt.ex`) — correct single owner; the scattered
  `requested?` checks are inherent to cooperative cancellation.
- `Exec` — right shape (single Port, kill-on-timeout, truncation); its only
  problem is that two tools do not use it.
- `Containment.walk/3` — correctly centralizes the walk discipline.
- `Permissions` merge logic (most-restrictive, intersection enablement).
- `Agent.Frontmatter` — clean isolation of YAML parsing and limits.
- `Bridge` and `Keymap` — single-purpose, data-driven, no core reach-through.
- `Compaction` (pure) vs `Compactor` (policy) — a real seam.
- The TUI mount-once config cache (`tui.ex:352-357`) — the right pragmatic fix
  for the per-frame TOML CPU storm; only the config *source* is misplaced.

---

## TODO — priorities

Open items only. Completed work is not kept here (git history and the
ADRs are the record); this list is the live backlog. Ordered by
leverage.

- [~] **P3 — Session storage decision (Section 4b).** ADR 020
      (`docs/source/decisions/020-session-storage.rst`, *Proposed*)
      settles the direction: **one SQLite DB per selectable store**
      (many sessions inside; the per-session-file draft was reversed
      2026-09-20), agent view + immutable display view as separate,
      session-keyed tables; R0 (session management is a first-class
      surface) leads it.
      Slice 1 shipped: the TUI picker now shows storage footprint per
      session and a total, filters live, toggles this-dir/whole-store,
      and bulk-deletes the visible set (delete-by-directory). `Store.list`
      entries carry `:size` and `:scope_root`. Slice 2 shipped: store
      selection — `config.toml [stores]` (name → path), `--store` on
      `mix tui` (the CLI was retired), `AGENT_STORE`, and `config.toml store =`,
      resolved in one `Core.Config` reader (`resolve_store/2`,
      `select_store!/2`); the picker names the active store. Not yet
      done: the engine change (per-store SQLite, session-keyed
      agent/display tables), export/import (blob migration is ignored —
      unreleased). The opencode objection was an API objection — missing
      verbs — which these slices address before any format change.
- [ ] **P4 — Split `tui.ex` along its own comment sections**; single state
      struct definition. (Grew to ~3200 lines; the mount state is still
      defined twice.)
- [ ] **P4 — `TranscriptView.metrics/…`.** One home for pane geometry; render,
      clamp, hit-test and status all use it.
- [ ] **P4 — Replace `test_mode?` branches with injected behaviours** where it
      has already let bugs slip.
- [ ] **P4 (cosmetic) — the session id left the frame with the bottom row.**
      The row was dropped (2026, `ui_redesign.md` §7): the composer's meta row
      already answered "what is happening now", and the row's own label was a
      second renderer of the same status. With it went the visible session id.
      The id still lives in the state and in the picker (ADR 020). If it should
      be visible while typing, it needs its own slot (a sidebar row or the
      picker head) — not more spans on the meta row.
- [ ] **P4 (cosmetic, Track B step 6/E) — glyph passes.** The status
      vocabulary is centralized (`Styles.status_badge/1`), but three
      surfaces still use plain text or ad-hoc glyphs:
      - approval dialog (`tui.ex:~3138`) still prints `y = approve …`;
      - transcript info/warning/error lines (`tui.ex:~1790`) carry a `✖`
        baked into the message string instead of a role-chosen leading
        glyph;
      - picker rows (`tui.ex:~3023`) use `to_string(status)` instead of
        `Styles.status_badge/1`.
      Cosmetic; width-safe geometric glyphs only.

---

# TODO — rival opencode (strategic gaps)

Observed 2026-09-21 by running this harness **and** opencode side by side
on the *same model*. The conclusion that prompted this list: the TUI
agent is not a worse model, it is the same model in a chassis with no
steering. Its whole system prompt is two sentences, its toolbelt is nine
tools with no planning or delegation, several parsed agent fields are
never consumed, and a repeated-failure loop surfaces as a confusing
error rather than steering. Ordered by leverage — the top three change
how the agent *behaves*; the rest are surface area.

- [ ] **T1 — Write the real framework prompt + per-agent role prompts.**
      `Core.Session.Prompt`'s built-in layer is two sentences
      (`prompt.ex:20-23`), and `build.md`/`plan.md` bodies are a short
      paragraph each. opencode ships a large, opinionated system prompt;
      the difference in behavior is not subtle. This is the single
      highest-leverage change and is really the "seed the agents with
      harness + role guidance" discussion: (a) the framework layer should
      state the harness contract (you are in a TUI agent; a human reads
      the stream and answers the gate; how to behave, when to ask), and
      (b) each definition body should say how to *live* the role (what
      "plan" means, what evidence "build" must produce). Keep role
      specifics in the definition (ADR 017), harness facts in the
      framework layer.
- [ ] **T2 — A doom-loop guard.** opencode detects the same tool call
      repeated (its `doom_loop` permission, default `ask`) and re-prompts
      with a nudge. This harness has only a per-turn `max_tool_rounds`
      cap, and when it trips the live report is that the agent "complained
      about flaky parallel calls" (`session.ex:62-76`). Detect N identical
      calls within a turn and inject steering ("you have called X with the
      same args three times; change approach or ask") *before* the cap.
      This is precisely the five-minutes-in-circles failure mode.
- [ ] **T3 — Consume the agent fields we already parse.** `temperature`,
      `max_turns` and `hidden` are read from frontmatter into
      `Core.Agent` and then **never used anywhere in `lib/`** (verified).
      A `maxTurns` that does nothing is worse than none (it is a lie in
      the docs). Either wire them (per-agent temperature into the request;
      `max_turns` as a real round budget with a summarizing stop) or
      remove them from the honoured-fields list in ADR 017.
- [ ] **T4 — `todowrite` / a plan tool.** opencode's `todowrite` is how
      the model organises multi-step work and stays on task across a long
      turn. This harness has no equivalent, so long tasks drift. Backlog
      B6 explicitly named "add a `todo`/`plan` tool" as an option; the
      plan agent now produces no durable artifact, so this is also the
      natural place a plan could live. Needs a small UI surface too.
- [ ] **T5 — `task` / subagent execution (the ADR 017 seam).** Defined in
      ADR 017 and ADR 018 (tab per subagent, summary-only return,
      depth 1) but never implemented. This is the biggest *architectural*
      gap: without it there is no delegation, no parallel exploration, and
      no context isolation. It is also the prerequisite for the
      specialist/repository matrix (ADR 007) that is the product thesis.
- [ ] **T6 — `question` tool.** opencode lets the model ask the user a
      structured multiple-choice question mid-task; ADR 018 and the gate
      have no channel for it. Cheap to add (the approval dialog already
      exists as a pattern) and removes a real failure mode: the agent
      guessing instead of clarifying. Note ADR 017 says a *subagent* may
      not ask; a primary may.
- [ ] **T7 — Slash commands / a command palette.** opencode's `/new`,
      `/sessions`, `/models`, `/compact`, `/export`, `/editor`, `/undo`,
      `/redo`, `/help` are a discovery surface we have as scattered keys.
      The picker covers sessions; export shipped. A small `/` palette that
      names the existing actions (and becomes the home for future ones)
      would make the tool legible instead of keybinding-archaeology.
- [ ] **T8 — Undo / redo (git checkpointing).** opencode's `/undo` reverts
      the last message *and* its file changes, via git. This harness has
      "Git is the undo" as an ADR 015 principle but no user-facing verb;
      the user must know git. A checkpoint per turn + `/undo` is a
      meaningful safety net that pairs with the permission story.
- [ ] **T9 — `websearch` (discovery) alongside `webfetch` (retrieval).**
      ADR 013 shipped `webfetch` only. opencode distinguishes search from
      fetch; without search the agent cannot find *which* URL to read.
- [ ] **T10 — Richer tools: `apply_patch`, LSP, skills, MCP/custom
      tools.** Lower leverage for this project's dogfooding, but each is a
      capability opencode has: patch-based edits (one atomic multi-file
      change), code intelligence (definitions/references/hover), skills
      (`SKILL.md`), and MCP/custom-tool extension without a rebuild. The
      `edit` tool is exact-match only today; opencode runs the model's
      `oldString` through a chain of NINE increasingly fuzzy replacer
      strategies (exact → line-trimmed → whitespace-normalized →
      indentation-flexible → escape-normalized → block-anchor with
      Levenshtein), and reports LSP diagnostics inline after every edit.
- [ ] **T12 — Provider-specific prompt files + an environment block.**
      From the opencode prompt-construction write-up (rmk40 gist,
      2026-09-11): opencode ships several static prompt files and selects
      one by model ID (`anthropic.txt`, `gemini.txt`, `qwen.txt`,
      `beast.txt` for GPT/o-series, `codex_header.txt` for GPT-5), and it
      generates a per-call **environment block** (model name, working
      directory, platform, today's date) into the system prompt. We send
      ONE five-line framework prompt to every model, local Ollama models
      included, and NO environment block (verified) — so the model does
      not know its cwd, platform, or the date. A small, high-leverage
      sibling of T1: per-model prompt selection + a generated env block.
- [ ] **T13 — Incremental instruction discovery (nested `AGENTS.md`).**
      opencode injects instruction files not only at session start but
      DURING tool execution: when `read` touches a file, it walks up from
      that file's directory for instruction files not yet loaded and
      injects them as `<system-reminder>` blocks, with a per-message
      dedupe. We read the scope root's `AGENTS.md` ONCE at session start
      (`Core.ProjectMemory`), so in a monorepo with per-package
      `AGENTS.md` the inner ones are silently invisible. The discovery
      walk is shared with the initial load (`ProjectMemory` already holds
      the file policy).
- [ ] **T14 — Tool-output truncation should spill to a retrievable file.**
      opencode's universal truncation (2000 lines / 50KB) writes the full
      output to a temp file and tells the model to `Grep`/`Read` it or
      delegate to an explore subagent. We truncate and DISCARD: `shell`
      keeps head+tail, `grep` caps at `@max_results`, `webfetch` at
      128 KiB. The elided content is unrecoverable — the model cannot go
      back for the part that was cut. The session scratch (ADR 022)
      already exists as a place to spill, so this is a change to the
      truncation path, not new infrastructure.
- [x] **T11 — The store flake (done 2026-09-21).** Chasing the flake
      found the real root cause, which was NOT the async env races I first
      suspected (those were real but incidental; fixed by `async: false`).
      The store opened a **new SQLite connection per call** — a leftover
      from the FILE store it replaced, where one action was one
      `File.read`/`write`. The suite's many processes then raced one DB
      file, and SQLite's unfair busy handler starved waiters (29/32
      writers failed), surfacing as `"database is locked"` and silent
      empty listings (`menu_popup == nil`, a renamed session missing from
      the list). `Store` is now a GenServer that owns one connection per
      store path (`81c5c8b`). A stale ctrl-x menu timer (cancelled when
      the prefix is consumed, `b9a1ceb`) and one test that polled a file's
      existence instead of its content were the other two flakes. 0
      failures in 60 full-suite runs.

Surface already present (so not listed): mouse-wheel scroll, alt-enter
send, Tab agent switch, model menu, session picker/search/export, status
spinner, reasoning display, esc-to-stop/quit.

---

# TODO — dog-fooding blockers (urgent)

Found by using the TUI on real work. None of these are architectural; they
make the tool annoying enough to avoid, which is worse than a bug. B1, B2
and B4 are **done** (see git history / ADR 021); the three below are the
live state. Root causes were read from the tree as reviewed; where a
mechanism is not pinned, that is said plainly instead of guessed.

- [~] **B3 — No mechanism to attach or select files in the message field.**
      Not started (Track C). The design in the finding stands: an `@`
      word-start trigger reusing the picker/menu surface, sourced from
      `Core.Tools` under `Tools.scope/1` + `Mounts`.

- [~] **B5 — The input field does not auto-wrap.** DEFERRED by owner
      decision (2026-09-19): accept for now, do not spend time on it —
      there are real features to implement. Recorded with the measurement
      so re-evaluation is cheap.

      Symptom: a long line runs off the right edge (the box grows per
      *line*, not per wrapped row). Root cause, corrected: there is **no
      `wrap` field to set.** The `%Textarea{}` struct has no wrap field;
      `wrap` exists only on `Paragraph`/`Markdown`/`CodeBlock`, not the
      textarea. Measured against the vendored `ratatui-textarea` 0.9.2
      (`ex_ratatui` 0.13.1): a 56-char value in a 20-col textarea renders
      only the first ~20 cols, and with the cursor at the end it
      **scrolls horizontally to the cursor** (shows the tail, not the
      head) — so the cursor is not lost, but the line start and the
      overall shape are. `input_height/1` measures
      `textarea_line_count/1` (newline count), so wrapping would have to
      feed the height math too (the measure/render agreement rule this
      file lives by).

      Options if revisited: (a) soft-wrap in our own render layer —
      pre-wrap the value to the input width, map cursor row/col to the
      wrapped position, drive `input_height/1` from wrapped rows (honest,
      real text-layout component); (b) patch/vendor the textarea upstream
      (Rust NIF, not landable in this repo); (c) a horizontal "more text
      right" indicator (does not solve the review's symptom alone).

- [x] **B6 — Plan mode is useless in its current configuration.** **Done
      (2026-09-21).** Direction: build/plan is a SIGNAL to the agent, not a
      sandbox/mode state. Plan now keeps `shell` as `shell: read_only`
      (scope root bound `--ro-bind`), disallows `edit`/`write_file`/`git`,
      and produces no durable artifact (the plan IS the transcript). All
      three questions answered; see ADR 017 "Read-only shell". The original
      finding text follows.

      Symptom: switching to plan gives no practical value in a normal session.
      Root cause: `priv/coding-agent/agents/plan.md` denies
      `disallowedTools: edit, write_file, shell, git`, so plan can only
      `read_file`, `grep`, `glob`, `list_dir` — it can analyse but cannot
      produce anything durable (no plan file, no todo list, no way to hand work
      off except prose in the transcript), and it is visually identical to build
      (B4), so it feels like build with fewer tools rather than a mode.
      Also note how much of the difference the *tool layer* even sees: the
      permission layer treats `disallowedTools` as a deny-list intersected with
      the allow-list (`core/permissions.ex:139-171`), so "plan" is defined
      entirely by absence.
      Fix direction: a configuration/definition decision, not a code fix.
      Settle three questions: (1) what is plan *for* — analysis, or producing a
      durable plan artifact (if the latter, grant a scoped write, e.g. a single
      plan/findings file, or add a `todo`/`plan` tool it may write); (2) is plan
      a *mode* (changes what send means, changes the composer/status, visibly
      distinct) or just an agent name; (3) does plan need the read-only network
      tools (`webfetch`) and subagents to be worth entering. Until (1) and (2)
      are answered, plan stays decorative.

**Status (2026-09-21).** B1, B2, B4, **B6 and B7 are done**; the `Styles`
vocabulary, the one-authority input executor (ADR 021) and the
status/activity spinner (Track B) shipped, and B7 shipped via ADR 022
(`Scratch` module, `session_id` scope seam, `Bwrap` bind over `/tmp`,
store cleanup). B5 (input wrap) is **deferred by owner decision**; B3
(file picker) is the only open B-item. B6 shipped: plan is a
permission-defined agent with a read-only shell (no mode chrome, no
durable artifact). The glyph passes (E) are the remaining cosmetic work.

<details>
<summary>B7 finding (resolved) — kept for the record</summary>

The agent wrote intermediate files to `/tmp`, and the next tool call
found the directory empty: every tool call ran in a fresh bwrap
namespace whose `/tmp` was a fresh tmpfs
(`lib/coding_agent/core/sandbox/bwrap.ex`), so `/tmp` was per-call
scratch by construction. ADR 022 replaced that with a per-session host
scratch dir (``System.tmp_dir!/0/coding-agent/<id>``) bound over
``/tmp``, with ``TMPDIR=/tmp`` exported, cleaned by the session
lifecycle verbs.
</details>

### Open backlog from the 2026-09-19 UI review (commit `bbd7f2f`)

The Track A review's mechanical defects (A footer position, E separator,
F role aliases, G stale ADRs, H modifier merge, C phantom `badge_list`)
and its two structural P2 items (one-authority input executor, modifier
fallback lattice, action-coverage tripwire) are **done** — see ADR 021
and commits `7a055ac`/`3e4c6c3`. What remains from that review:

- [ ] **P3 — `shift+tab` (crossterm `back_tab`) is unbound.** Pre-existing
      (not a Track A regression), same bug class: a shifted key that the
      terminal reports as a distinct code and the keymap never bound. The
      lattice makes other shifted specials fall back, but `back_tab` is
      its own code, so it stays unbound until the intent vocabulary
      (ADR 021) decides what it means.

---

# UI — styling and visual consistency

**IMPLEMENTED (steps 1-4 of the sequence below).** `CodingAgent.UI.Styles`
now owns roles (`role/1`), badges (`badge/2`), a definition list
(`definition_list/1`), panels (`panel/1`), section headers, chrome fills
and `status_badge/1`. (`badge_list/1` from the original sketch was
dropped: the input footer needs the `agent · model` identity shape,
not a `·`-joined list, so `badge/2` composed inline is the real
primitive.) The ~35 inline `%Style{}`
sites in `tui.ex`/`transcript_view.ex` are gone (only genuinely-empty
styles and the `Styles` module itself remain); box footers and the input
footer use role-styled identity; the sidebar is a `definition_list` with
a truthful `" status "` title and agent badges. `styles_test.exs` covers
the vocabulary. Not done: a swappable theme (step 5 — deliberately, no
config surface is wanted yet).

**Revised (visual pass, see `ui_redesign.md`).** Three things changed on
live feedback:

- the **fills and the body text are now stated indexed colours**, not
  named ANSI slots. A named colour is a slot in the user's theme, and the
  observed theme rendered ANSI 15 as washed-out grey (the "text looks
  tempered" report) and ANSI 8 as near-invisible. The *semantic* colours
  (warning/error/agent/model/user/accent) stay named on purpose — their
  meaning is "whatever this terminal calls red/cyan".
- the **composer is no longer a box**. It is a filled field on the chrome
  grey with no border, its identity line and the status sharing one bottom
  row (`Styles.panel(borders: [], surface: :chrome, titles: [...])`). The
  frame read as "c64"; measuring showed a widget-level bg fills only the
  rows the widget writes, so `Styles.panel/1` now defaults the block's
  `style` to the surface fill. `input_height/1` reserves one line for the
  bottom title (it used to reserve two border rows) — `measure = paint`.
- colours are asserted through `ExRatatui.CellSession` (`TuiCase.start_cell_tui/2`,
  `cells/1`, `cell/3`): `buffer/1` carries symbols only and can never catch
  a colour regression (`test/coding_agent/ui/tui_cells_test.exs`).

Goal: a small, central vocabulary for "how a piece of information looks", so
that every surface renders the same concept the same way. Today there is no
such vocabulary, and it shows.

## The current state

Style values are written inline at ~35 sites. The same concept is expressed
with different raw values in different places:

- Colors are chosen ad hoc: `:dark_gray` 18×, `:white` 10×, `:yellow` 3×,
  `:cyan` 3×, `:magenta` 1×, `:gray` 1×. There is no stated meaning. Is
  `:gray` the same role as `:dark_gray`? Today they are used interchangeably
  for "muted" in different files.
- Borders: the input box and assistant box use `:rounded`; the transcript tool
  box and sidebar use different border styles; border colors are `:dark_gray`,
  `:cyan`, `:magenta`, `:yellow` with no rule.
- The sidebar panel (`tui.ex:2412-2513`) is titled `" agent "` but contains
  session id, effort, token counts and compaction info. It is a status panel
  wearing an agent label.
- Label/value rows (`session` / id, `context` / counts) are hand-assembled with
  hardcoded `Text.Span.new` calls and blank `Text.Line.new([...])` spacers.
- `TranscriptView.agent_block/2` (`transcript_view.ex:208-218`) is the one
  good precedent: a single function that owns the frame, with `title_style`
  hardcoded and `border_style` passed in. The footer strings are already
  centralized (`user_footer/1`, `agent_footer/1`). Extend this pattern.

## Proposal: a `CodingAgent.UI.Styles` module

Not a "theme" (that implies swappable palettes and a config surface we do not
need yet). A **styles** module: semantic roles plus small builders for recurring
visual elements. Raw colors live only here.

### 1. Semantic roles, not colors

Expose roles, never `%Style{fg: ...}` literals from call sites:

```elixir
Styles.role(:muted)      # secondary text, hints, labels
Styles.role(:value)      # primary readable text
Styles.role(:accent)     # interactive focus (input border, selection)
Styles.role(:user)       # the user's voice
Styles.role(:agent)      # assistant identity
Styles.role(:model)      # model identity
Styles.role(:reasoning)  # thinking text
Styles.role(:info)
Styles.role(:warning)
Styles.role(:error)
Styles.role(:success)
```

The role-to-`%Style{}` mapping is the single place colors are chosen. Changing
"what muted looks like" is then a one-line edit, and `:gray` vs `:dark_gray`
stops being a per-author guess.

### 2. Badges — your `<AGENT NAME:plan>` / `<MODEL:glm-5.3>` example

A badge is a label plus a value with a stable visual identity, returned as a
`Text.Line`/spans so it can go in a `Block.title`, a `Paragraph`, or a table
cell. `Block.title` and `Block.titles` accept line-like values
(`block.ex:11-21`), and `Block.Title` carries its own position/alignment/style,
so badges can sit on top-left, top-right and bottom borders simultaneously.

Sketch:

```elixir
Styles.badge(:agent, "plan")     # e.g. dim label "agent" + accent "plan"
Styles.badge(:model, "glm-5.3")
# A badge list as first sketched was dropped: the footer needs an arrow
# relationship ("you → plan"), not a `·`-joined label list.
```

Then the assistant/user box footer, which currently builds strings via
`TranscriptView.user_footer/1` / `agent_footer/1`, becomes a badge list. The
input footer (`tui.ex:2338-2353`) gets the same treatment, so the footer reads:

```
you → plan   ·   model glm-5.3
```

with `plan` and the model in their role colors, instead of one flat
`dark_gray` title.

Consistency rule this buys: an agent name is *always* the same color and shape
wherever it appears (box footer, sidebar, picker, approval dialog), and a model
name likewise.

### 3. Definition list — your "table in the panel" question

This is a **definition list** (key/value rows), not a data table. Use
`ExRatatui.Widgets.Table` only when there are real columns being compared
across rows. For the sidebar, a def-list is the right primitive: label in
`:muted`, value in `:value`, aligned, with a single spacing rule.

```elixir
Styles.definition_list([
  {:session, "tui-1730…"},
  {:effort,  "default"},
  {:context, "58.3k tok in"},
  {:window,  "12% of 500k"},
  {:compact, "at 180k"}
])
```

Returns lines for a `Paragraph`, or a `Paragraph` directly. This replaces the
hand-built span/blank-line assembly in `sidebar_widget/1`
(`tui.ex:2442-2512`), which is exactly the code that currently drifts.

If a section genuinely needs aligned columns (e.g. "last turn / cumulative /
limit"), then a small `Styles.table/2` wrapper over `ExRatatui.Widgets.Table`
with `header_style` from a role and `column_spacing` fixed is the second
primitive. Keep the count of primitives small: badges, def-list, table,
section header.

### 4. Section header and panel

```elixir
Styles.section_header("context")          # a muted, slightly emphasized line
Styles.panel(title: "status", badges: [...])
```

`Styles.panel/1` should own the `Block` construction (border type, border
color by role, padding, title placement) so the transcript boxes, sidebar and
dialogs stop each picking their own border style. This generalizes the existing
`TranscriptView.agent_block/2`.

Fixing the sidebar title is part of this: it says `" agent "` but is a status
panel; with `Styles.panel(title: "status")` plus badges for the active agent
and model, the panel becomes truthful and the identity moves to a badge.

### 5. Consistency rules to write down (and then enforce)

- One meaning per color role; call sites name the role, never the color.
- All borders `:rounded`; border color is chosen by role
  (`:accent` for focused/input, `:muted` for passive panels, `:warning` for
  the approval gate).
- Muted text is one role (`:muted`); delete the `:gray`/`:dark_gray`
  distinction unless a deliberate third level is introduced.
- Label/value rows always come from `definition_list/1`; no hand-built
  `Text.Span` label pairs.
- Identity (agent, model) always uses a badge.
- One spacing token (e.g. `Styles.gap/0`) instead of ad hoc blank
  `Text.Line.new([...])`.

## Suggested sequencing for the UI work

1. Introduce `UI.Styles` with roles only. Mechanically replace the ~35 inline
   `%Style{}` literals with role lookups. No visual change intended; this makes
   the vocabulary exist. (Tests that assert on style/color may need updating.)
2. Add `badge/2`; move the box footers and the input footer onto it
   (`badge_list/1` proved unnecessary — the footer needs the arrow shape).
3. Add `definition_list/1`; rewrite the sidebar (`sidebar_widget/1`) with it,
   and correct the panel title to `"status"`.
4. Add `section_header/1` and `panel/1`; fold `TranscriptView.agent_block/2`
   and the sidebar/dialog `Block`s into `panel/1`.
5. Only after that, consider a real theme (palette swapping, user override via
   `config.toml`) — the role indirection makes it cheap later.

Note: the sidebar also carries the `Application.get_env(:context_window_tokens)`
and `Compactor.trigger/0` reads (`tui.ex:2414-2420`). Those go away with the
`Config.snapshot/1` work above; the sidebar should receive a prepared status
struct and only paint it. That keeps `Styles` a pure presentation module with no
config or domain dependencies.

---

# UI — status, activity and animation

This extends the styling work. The theme: **the status is about the input, so it
belongs at the input; and a silent agent is indistinguishable from a broken one,
so activity must be visible.**

## Where things are today

(The state this review was written against. What shipped since: the row is
gone — `ui_redesign.md` §6 and §7. The composer is a filled, borderless panel
in its own module, and its meta row carries identity, status and the transient
text; the window's last row is the composer's own bottom padding.)

Layout (`render_main/2`, `tui.ex:1810-1861`):

```
┌─ sidebar (left) ──┐
│                   │   transcript (middle, reading measure)
│                   │
│                   │   ▏composer: a filled field, no frame
│                   │   ▏you → plan · glm-5.3        ⠋ running mix
└───────────────────┘   status row (bottom, full width, 1 line)
```

- The status row is split off first, full width, at the very bottom
  (`tui.ex:1820-1824`), while the composer is only reading-measure wide
  (`tui.ex:1840-1844`). So the status is visually detached from both the input
  and the transcript. (The composer is a **filled field with no frame** since
  the visual pass — `borders: []`, the chrome grey, one bottom title row for
  identity + status. The remaining duplication above still stands: the bottom
  row repeats the label.)
- `status_widget_plain/1` (`tui.ex:2671-2715`) packs four unrelated things into
  that one line: session id, a glyph + status label, esc-confirm hints, and
  **scroll diagnostics** (`scroll: 3/120 (48 entries, tools shut, h: 22 w: 78)`).
  The diagnostics are debug output shown to the user.
- The glyphs already exist but are not a system:
  `:running → "●"`, `:interrupting → "◐"`, `:idle → "○"`,
  `:interrupted → "⏸"`, `:error → "✖"` (`tui.ex:2690-2697`).
- There is **no spinner and no notion of "how long since the last activity"**.
  Tools run synchronously on the worker (`Session.execute_tools/2`,
  `session.ex:1227`) with no `tool_started` event — only `tool_executed` when
  they finish (`session.ex:1303`). During a long tool or a silent model, the UI
  shows a static `●`.

## A. Move the status to the input footer

The status answers "is the model still working on what I asked?". That question
is asked *at the input box*.

*(Shipped, in a later shape: the status glyph + spinner + label sit on the
composer's meta row, and the bottom row was dropped entirely —
`ui_redesign.md` §6/§7. The text below is the original proposal.)*

Put it on the input box's top border, opposite the
existing bottom footer:

- Input box `Block` gets two titles: bottom-right keeps
  `you → plan · glm-5.3` (identity), top-right carries the status badge +
  spinner. `Block.titles` supports per-title alignment/position
  (`block.ex:15-27`), so no layout surgery is needed.
- Result: the working state sits directly above where you type, and it is inside
  the same frame as the identity, so it reads as one composed control instead of
  a detached footer strip.
- The freed bottom row goes away entirely, or is repurposed for the diagnostics
  line only when a debug flag is on (see D). This also removes the awkward
  `{:min, 0}, {:length, 1}` top-level split at `tui.ex:1820`.

Alternative if you want the status to also be visible while scrolling the
transcript: keep a 1-line row but place it directly *above* the input box rather
than at the window bottom, and narrow it to the input width. Either way the key
change is "attached to the input", not "pinned to the screen bottom".

**Shipped, one round later:** the row is gone entirely, and the transient text
(esc hints, menu note, debug diagnostics) moved onto the composer's meta row —
which is why it kept a spare *right half*. See `ui_redesign.md` §7.

## B. Status as a traffic-light badge

Replace the raw `{glyph, color, label}` tuple with a badge built by `Styles`:

```elixir
Styles.status_badge(:running)      # ● running
Styles.status_badge(:interrupting) # ◐ stopping
Styles.status_badge(:idle)         # ○ idle
Styles.status_badge(:interrupted)  # ⏸ approval needed
Styles.status_badge(:error)        # ✖ error
```

Rules:

- The color mapping lives in `Styles` (one place), reusing the roles from the
  styling section: `:running` → `:success` (green), `:interrupting`/approval →
  `:warning` (yellow), `:error` → `:error` (red), `:idle` → `:muted`.
- Prefer a filled/hollow circle pair for running/idle and a distinct shape for
  each terminal state; the current set is already close, so keep those glyphs
  and just give them one home.
- Keep it text, not emoji. Emoji width is unreliable across terminals (some are
  double-width, some fall back to tofu), which breaks the single-line footer
  math. Geometric Unicode (`● ◐ ○ ⏸ ✖ ✔`) is safe. If you want a colored dot,
  color it with the role style rather than using 🔴/🟢.
- Add `:success` role for a completed/clean state so `idle` and "last turn
  succeeded" can be distinguished later.

## C. A spinner for "still working, no output"

This is the valuable part, and it needs one real mechanism addition.

### C.1 Animation driver

`ExRatatui` already has the right primitive: subscriptions
(`ExRatatui.Subscription.interval/3`, reconciled by the server and dispatched as
a message the app receives in `handle_info/2` — `server.ex:437`, `app.ex:244`).
This is strictly better than the ad hoc `Process.send_after(:__resize_poll__, …)`
pattern the TUI uses (`tui.ex:229`, `1750-1770`).

Declare, only while busy:

```elixir
def subscriptions(state) do
  if state.status in [:running, :interrupting] do
    [Subscription.interval(:spinner, 120, :__spin__)]
  else
    []
  end
end
```

and handle `:__spin__` by advancing a frame index in state. 120 ms gives a calm
~8 fps. Because the subscription is reconciled from state, it stops on its own
when the turn ends — no manual cancel.

`subscriptions/1` is an `@optional_callback` (`app.ex:256`) and the TUI uses the
callback runtime, so this should drop in; the existing `:__resize_poll__` timer
can later move to the same mechanism.

### C.2 What the spinner reports

A spinner is only useful if it says *what* is being waited on. Two sources:

1. **Model silence.** Track `last_activity_at` (monotonic ms) in TUI state,
   updated on every `llm_deltas` / `reasoning_deltas` / `tool_executed`
   (`tui.ex:1578-1711`). Then:
   - `< 1.5 s` since last delta → spinner, "thinking"
   - `> ~5 s` with no delta → spinner + "thinking · 12s" (a duration), which is
     exactly the "model goes silent" case you hit.
2. **Tool work.** Today there is no start event, so the UI cannot say "running
   mix". Add a `{:tool_started, name}` broadcast in the round before execution
   (`Session.execute_tools/2`, `session.ex:1227`, or in `gate_tools/2` before
   `execute_tools` at `session.ex:1059/1069`). The TUI then shows
   `◐ running mix · 38s` — the "mix ran for a minute" case. This is a small
   core change: one event, following the existing `broadcast/2` pattern
   (which the `Events` module todo will formalize).

Note the spinner should be driven by activity timestamp, not merely
`status == :running`, so a genuinely stuck turn visibly diverges ("thinking ·
45s") from a healthy fast one.

### C.3 Spinner style

Braille frames `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` are the common choice and are single-width
in practice. Provide them in `Styles.spinner(frame)`, so the frame set is data,
not string literals in the render path. Fall back to `|/-\` if you later detect
a limited locale, but braille is fine for a dev tool.

## D. Split the status line: user status vs debug diagnostics

`status_widget_plain/1` currently shows `scroll: … (48 entries, tools shut,
h: 22 w: 78)` to every user (`tui.ex:2687-2699`). That is developer output. With
A–C the user-facing row becomes: status badge + spinner + elapsed + esc hints.
Move the scroll diagnostics behind a debug toggle (there is already a
`ctrl-x p` hides-panel binding and a `sidebar_visible?` pattern to copy), or
fold them into the sidebar. This is a one-line-per-caller change but it is what
makes the status line look intentional rather than like a debug console.

## E. Smaller Unicode opportunities (only where they earn their place)

- **Approval dialog** (`tui.ex:2824`): mark pending calls with `⏸`/`❯` and use
  `✔`/`✖` for approve/reject hints instead of `y/n/e` plain text, keeping the
  letters as secondary text.
- **Info/warning/error transcript lines** (`tui.ex:2096`, `1713-1715`): a leading
  role glyph (`·`, `⚠`, `✖`) chosen by `Styles` role, so severity is scannable.
- **Compaction notice**: an hourglass `⧗` or the existing `·` with `:warning`
  role — it is a long operation and should look like one.
- **Picker rows** (`tui.ex:2718-2736`): status per row is plain text
  (`to_string`); give it the same status badge vocabulary.

Do **not** Unicode-ify everything. Every glyph is a width risk and a
font-dependent tofu risk; add them where they encode state (running, warning,
error, approval) and leave prose alone.

## F. Sequencing

**IMPLEMENTED (steps 1-5).** Status/activity shipped:

- step 1: `Styles.status_badge/1` + roles (in the `Styles` pass);
- step 2 (A): the status badge + spinner render next to the composer's
  identity line (originally the input box's TOP-RIGHT border; since the
  visual pass the composer is a borderless filled field and the two share
  its bottom row — see `ui_redesign.md`);
- step 3 (D): the scroll diagnostics are behind `debug_visible?`
  (`ctrl-x d`); the esc hints live on the composer's meta row now, the
  diagnostics beside them (the bottom row was dropped — `ui_redesign.md` §7);
- step 4 (C.1/C.2): a `subscriptions/1` spinner (`:spinner`, 120ms) runs
  only while `Styles.busy?/1`, and `last_activity_at` tracks silence —
  the status reads `⠋ thinking` or `⠋ thinking · 12s`;
- step 5 (C.2): core broadcasts `{:tool_started, name}`, so the status
  reads `⠋ running mix` for the duration of the call.
- step 6 (E, glyph passes: dialog/transcript severity/picker) is **not**
  done — cosmetic, tracked below.

Tests: `track_b_status_test.exs` (pure frame set + status line, the
subscription lifecycle, the input-border render, tool naming, the debug
toggle) and `tool_started_event_test.exs` (core: start precedes result).

The spinner turned "the app might be hung" into "the tool has been
running 38 s" — the single biggest perceived-responsiveness win after the
streaming fix. Still open: step 6 glyph passes (E — approval dialog,
transcript severity, picker).

---

# UI — animation options

Concrete inventory of what is available for spinners and activity animation,
grounded in what the dependency actually ships. The frame sets below were read
back from a test terminal (`ExRatatui.init_test_terminal/2` + `draw/2`), not
copied from docs, because the Elixir type and the Rust parser disagree (noted
below).

## Option A — `ExRatatui.Widgets.Throbber` (built in)

`deps/ex_ratatui/lib/ex_ratatui/widgets/throbber.ex` wraps the
`throbber-widgets-tui` Rust crate (declared in
`deps/ex_ratatui/native/ex_ratatui/Cargo.toml:15`). Fields:

```elixir
%ExRatatui.Widgets.Throbber{
  label: "thinking",
  step: 0,                 # caller increments on each tick
  throbber_set: :braille,
  throbber_style: Styles.role(:accent),
  style: Styles.role(:muted),
  block: nil               # can carry a Block, like other widgets
}
```

The caller owns the animation: increment `step` on a timer. The widget is
stateless in the app; `ThrobberState` is created per render
(`native/.../widgets/throbber.rs:41-42`).

### The real frame sets

Rendered and de-duplicated (order is the crate's cycle order):

| set | frames |
|---|---|
| `:braille` (default) | `⠾ ⠯ ⠟ ⠻ ⠽ ⠷` |
| `:braille_double` | `⠹ ⠏ ⠛ ⠼ ⠶ ⠧` |
| `:braille_one` | `⠂ ⠐ ⠠ ⠄ ⠁ ⠈` |
| `:braille_eight` | `⣻ ⣯ ⣟ ⡿ ⢿ ⣽ ⣾ ⣷` |
| `:braille_eight_double` | `⢻ ⣏ ⡟ ⠿ ⣹ ⣼ ⣶ ⣧` |
| `:dots` | `⠆ ⠰ ⠤ ⠃ ⠉ ⠘` |
| `:vertical_block` | `▃ ▂ ▄ ▅ ▆ ▇ █ ▁` |
| `:horizontal_block` | `▍ ▎ ▌ ▋ ▊ ▉ █ ▏` |
| `:ascii` | `| / - \` |
| `:arrow` | `↖ ↗ → ↘ ↓ ↙ ← ↑` |
| `:clock` | `🕘 🕧 🕐 🕜 🕑 🕝 🕒 🕞 🕓 🕟 🕔 🕠` (12) |
| `:box_drawing` | `│ ╱ ─ ╲` |
| `:quadrant_block` | `▝ ▗ ▖ ▘` |
| `:white_square` | `◱ ◲ ◰ ◳` |
| `:white_circle` | `◵ ◶ ◴ ◷` |
| `:black_circle` | `◐ ◒ ◓ ◑` |

**Type/parser mismatch to fix:** `throbber.ex:38-51` declares only 12 sets in
`@type throbber_set`, but the Rust parser accepts 16
(`native/.../widgets/throbber.rs:49-65`). `:braille_eight`,
`:braille_eight_double`, `:braille_one`, `:braille_double` all render but are
not in the type. Add them when this widget is used.

**Limitation:** a `Throbber` paints its own `Rect`. It cannot be placed inside a
`Block` title, so it cannot sit on the input box's border. It needs a dedicated
one-line row. That is the main reason Option B exists.

## Option B — span-based spinner (composable; what "status on the input" needs)

`Block.title` / `Block.titles` accept only line-like text values
(`deps/ex_ratatui/lib/ex_ratatui/widgets/block.ex:11-21`), not widgets. To put a
spinner on the input border, the frame set must be available as a string:

```elixir
Styles.spinner(:braille, step)   # -> "⠻"
Styles.spinner(:cylon, step)     # -> a fixed-width string (see Option C)
```

Then it composes anywhere text goes: a `Block.title`, a status badge
(`Styles.status_badge/2`), a `Paragraph`, a transcript line, a table cell.

The frame sets are the same data as Option A. Put them once in `Styles` (or a
sibling `UI.Spinner`) as a map of set => tuple of frames, and expose
`frame(set, step)` as `elem(frames, rem(step, tuple_size(frames)))`.

Recommended sets for this use: `:braille` (calm, 6 frames),
`:braille_eight_double` (denser, 8 frames), `:dots` (sparse) or `:ascii`
(fallback for limited terminals). Avoid `:clock` — it is emoji, and emoji width
is unreliable across terminals, which breaks the single-line footer math.

## Option C — the cylon / bouncing-bar effect

A hand-rolled fixed-width effect: a highlight scans back and forth along a bar.
It is just a set of precomputed equal-width strings, cycled on the tick. No
dependency, no widget.

Shape 1 — scanning head over a track (a "radar sweep"):

```
▁▂▃▄▅▆▇█▇▆▅▄▃▂▁
```

Shape 2 — a block bouncing across a fixed width (the classic cylon eye), here
width 9 with a 3-wide head:

```
███░░░░░░
░███░░░░░
░░███░░░░
░░░███░░░
░░░░███░░
░░░███░░░
░░███░░░░
░███░░░░░
```

Shape 3 — a brightness ramp pulsing in place, for a short fixed slot:

```
▁ ▂ ▃ ▄ ▅ ▆ ▇ ▆ ▅ ▄ ▃ ▂
```

Implementation sketch:

```elixir
# UI.Spinner
@cylon_width 9
@cylon_head 3

def cylon_frames(width, head) do
  track = width - head
  # ping-pong 0..track..0, render each as blocks
  for i <- Enum.concat(Enum.to_list(0..track), Enum.to_list(track..0)) do
    String.duplicate("░", i) <> String.duplicate("█", head) <>
      String.duplicate("░", track - i)
  end
end
```

Notes:
- Width must be known. Either fix it (e.g. a short slot on the input border) or
  rebuild the frames when the pane width changes.
- Keep it in **one** prominent place. It is decorative and visually loud next to
  streaming text; using it in several places would make the screen busy.
- Good candidates for the cylon: the input status slot (your "is the model
  still working" location), or the approval-gate waiting state.
- Prefer `░`/`█` (light/dark shade) over a colored block so it reads on both
  light and dark terminals; color the whole thing with one role style if at all.

## Option D — `Gauge` / `LineGauge` for determinate progress

`ExRatatui.Widgets.Gauge` (`ratio: 0.0..1.0`, `label`, `gauge_style`) and
`LineGauge` exist. Only meaningful with a real percentage. For tool calls you
usually do not have one. Uses:

- Compaction: no real progress signal today (`Compactor` is a single summarize
  call), so a determinate bar would be a lie. Skip.
- An indeterminate *shimmer*: a `LineGauge` whose `ratio` oscillates (0→1→0) is
  a valid alternative animation, but it fills a whole line and is heavier than a
  spinner for the same "working" meaning.

## Option E — `Sparkline` for activity history

`ExRatatui.Widgets.Sparkline` (`data`, `bar_set: :nine_levels`, `direction`,
`absent_value_style`). Plot a rolling window — e.g. streamed bytes per tick, or
recent tool durations — so the user sees "still producing" over time rather than
an instant. Good sidebar material ("activity" sparkline next to the token
counts). Overkill before the spinner lands; keep in mind for the sidebar
definitions list.

## Option F — braille "dot abuse" via `Canvas`

Braille chars give a 2×4 sub-cell grid per character, so one cell can hold a
very fine animation or a tiny shape. `ExRatatui.Widgets.Canvas` exposes this via
`marker: :braille` (also `:dot`, `:block`, `:bar`, `:half_block`). This is how
you would build a custom radar/logo animation. Powerful, but a rabbit hole;
only justified if you want a signature effect.

## Recommendation

- Discrete state: `Styles.status_badge/1` (glyph from the table, role-colored) —
  already specified above.
- "Still working": **Option B** spinner (`:braille` or `:braille_eight_double`)
  on the input border, driven by the `subscriptions/1` tick. This is the default.
- **Option C** cylon as an opt-in alternative for the same slot, behind a
  one-line preference. Confine it to that slot.
- **Option A** `Throbber` only if you want a separate dedicated loading row; its
  real value here is the ready-made frame sets, which Option B reuses as data.
- **Option E** sparkline for the sidebar later; **Option F** only for a custom
  signature effect; **Option D** only when there is a real ratio.

## Concrete API sketch

Sibling to `Styles`, so the frame sets are data and the render path holds no
glyph literals:

```elixir
defmodule CodingAgent.UI.Spinner do
  @doc "One glyph for the given set and step. Cycles by remainder."
  @spec frame(atom(), non_neg_integer()) :: String.t()
  def frame(set \\ :braille, step)

  @doc "Frames for a set, as a tuple (data, not literals in call sites)."
  @spec frames(atom()) :: tuple()

  @doc "A fixed-width cylon (bouncing-bar) frame."
  @spec cylon(non_neg_integer(), pos_integer()) :: String.t()

  @doc "Advance the step only while the app is busy."
  @spec busy?(term()) :: boolean()
end
```

Driver in the TUI (callback runtime; `subscriptions/1` is an
`@optional_callback`, `deps/ex_ratatui/lib/ex_ratatui/app.ex:256`):

```elixir
# TUI
def subscriptions(state) do
  if Spinner.busy?(state.status) do
    # ExRatatui reconciles by :id, so this persists while busy and is dropped
    # automatically when the turn ends — no manual cancel.
    [ExRatatui.Subscription.interval(:spinner, 120, :__spin__)]
  else
    []
  end
end

def handle_info(:__spin__, state) do
  {:noreply, %{state | spin: Map.get(state, :spin, 0) + 1}}
end
```

120 ms is a calm ~8 fps. Because the subscription is declared from state, it
stops on its own when the turn ends. The existing ad hoc
`Process.send_after(self(), :__resize_poll__, 500)` (`tui.ex:229`, `1750-1770`)
can later migrate to the same mechanism.

`Spinner.busy?/1` should be driven by *activity*, not just `status == :running`,
so a stuck turn diverges visibly from a healthy one:

- Track `last_activity_at` (monotonic ms) on every `llm_deltas` /
  `reasoning_deltas` / `tool_executed` (`tui.ex:1578-1711`).
- `busy?` true for a grace window after the last activity while the status is
  `:running`/`:interrupting`; the status line then renders
  `⠻ thinking` → `⠻ thinking · 12s` once silence exceeds ~5 s.
- With the core `{:tool_started, name}` event (sequencing step 5), it becomes
  `⠻ running mix · 38s` — the "mix ran for a minute" case.

## Animation testability

The animation is pure data + a counter, which makes it testable without a
terminal:

- `Spinner.frame/2` is a pure function — assert cycle length and wrap.
- `subscriptions/1` is a pure function of state — assert it is empty when idle
  and non-empty while running.
- The tick handler is a pure state increment — inject `:__spin__` and assert the
  step advanced, then render and assert the buffer changed (the existing
  `TuiCase.buffer/1` + `fire/2` helpers already support this pattern).

---

## Dogfood finding (2026-09-20): the git tool could not commit from a worktree checkout

Found by dogfooding (review agent session in the worktree
`agentic-coding-assistant-mjansen`): `git commit` failed with
`Unable to create …/.git/worktrees/…/index.lock: Read-only file system`
in EVERY profile, including the `git` tool's own `git_write: true` one.

Root cause, read from the tree and the mount table:

- The scope root is bound read-write (`--bind root root`), which covers
  an in-tree `.git` — the plain-checkout case works.
- A **worktree checkout's `.git` is a gitfile** naming a gitdir OUTSIDE
  the scope root. Nothing bound that gitdir read-write; it was only
  covered by the read-only `/` base bind, so `index.lock` failed (EROFS).
- The `git` tool's premise ("grants `git_write: true`, so the agent can
  commit") silently failed for every worktree checkout — and the sandbox
  tests could not catch it: `triple_in/2`/`sublist?/2` match a
  non-consecutive subsequence, so a bind assertion can pass against a
  run that skips intervening flags (not an equality slice). The matcher
  is still gap-tolerant today; tightening it to a contiguous run is a
  cheap follow-up (the intended probe fix was reverted, not landed).

Fix: `bf59a58` (resolve the per-worktree gitdir from the gitfile AND the
shared common dir from `commondir`, bind `--ro-bind` for shell and
`--bind` for git_write; `argv/3` stays pure). Live-verified from the
worktree session with two throwaway probe commits (create + release
`index.lock` twice, since reverted) — the finding is closed.
