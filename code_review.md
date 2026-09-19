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
   being safe the moment sessions are *shared or imported* — an export
   feature turns a foreign session file into an atom-exhaustion /
   code-exec vector. Fix the trust boundary before shipping export.

Retention is also unowned: `--session-prune <days>` exists, but there is
no size cap and no documented policy (principle 5).

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

Ordered by leverage. Items 1–2 are contained and remove real bugs; do those
first.

- [x] **P1 — Streaming interactivity: defer the render, throttle the
      stream.** Deltas no longer paint (they return `render?: false`); a
      fixed-cadence `subscriptions/1` tick (`:stream_render`, 60ms) is the
      only stream render source and retires itself while the stream is
      quiet. Deleted `drain_deltas/2` (the mailbox `receive … after 0`
      starved input on a steady trickle). Also removed the duplicate
      per-frame `render_reasoning/1` in `entry_widgets/3` (display entries
      are already normalized) and corrected the `render_reasoning` /
      `harden_line_breaks` / `normalize_block` comments to separate
      markdown line-structure from the buffer/window trailing-newline
      invariant. Measured: 500 deltas used to cause up to 500 renders; now
      **0** — each throttle tick causes exactly one. New mid-stream
      interactivity test. (Report implemented and removed;
      `test/coding_agent/ui/tui_stream_burst_test.exs` is the record.)
- [x] **P1 — `Config.snapshot/1`.** New `CodingAgent.Core.Config`:
      one typed read of merged config, permissions, mounts, providers,
      agents; typed runtime-knob accessors with the single defaults
      (removed from `config.exs`); `state_dir`/`store_dir`; the no-model
      message. `Session.init` reads once and threads the snapshot;
      `Compactor`, `Sandbox`, `Store`, `TUI`, mix task, `Application`
      and `CodingAgent.model/0` all route through it. Deleted the dead
      `UserConfig.model/1`; renamed `project_dir_for_test/1` to a real
      `project_dir/1`; cached the per-file layers so the merge and the
      mount schema share one read. New `config_test.exs`.
- [x] **P1 — Fix the compactor `Request` divergence.** `effective_model/1`
      moved to `Session.State` and `Compactor.summarize/2` now builds
      with it and keeps `Request.build`'s base opts (base_url/api_key).
      (Bug 4.1.)
- [x] **P1 — Route `grep`/`glob` through `Exec` + `Sandbox`.** `rg`/`fd`
      now run through the one executor under `Tools.profile/1` (scope +
      mounts, no network/git-write) instead of a bare `System.cmd`.
      Added `Mounts.empty/0`. (Bug 4.4.)
- [x] **P2 — Core `Events` module.** `Core.Events` owns the event
      vocabulary and `publish/2`; `Session`, `Compactor`, `ProviderHealth`
      and `Session.subscribe/1` all use it. New `events_test.exs`.
- [x] **P2 — Shared `ToolCall.normalize/1`.** `Core.ToolCall` is the one
      normalizer; `Session.call_parts/1`, the CLI's and the TUI's
      `call_info/1` are deleted. New `tool_call_test.exs`.
- [x] **P2 — Move failure classification into core.**
      `Core.Failure.classify/1` (+ `provider_reason/1`) is the one
      classifier; `Tui.classify_failure/1` delegates and
      `ProviderHealth` uses the provider path. Test moved to
      `core/failure_test.exs`. (Section 1.3.)
- [x] **P2 — `Session.resume/2` factory + canonical `resume_opts/1`.** CLI
      and TUI stop reconstructing state. `State.restore/1` now owns
      snapshot healing (moved out of `Store`); `Store.rename` calls
      `Session.notify_renamed/2` instead of reaching the registry.
      (Bugs 1.2, 4.2; Section 3.)
- [x] **P3 — `Session.Gate` + `Session.ToolRunner` extraction.**
      `Core.Session.Gate` owns the gate decision + call bucketing and
      `Core.Session.ToolRunner` owns tool exposure and execution.
      `Permissions.effective/4` is now the real production path (the
      gate supplies a confinement-aware `:fallback`; `matching/3` is
      gone). Also extracted `Core.Text` for the UTF-8 scrub. New
      `session/gate_test.exs`. (Bugs 4.3; Section 5.)
- [x] **P3 — Single `Containment.resolve` + `Mounts.empty/0`.** The
      three private `check_scope` copies now call
      `Containment.check_scope!`; all six empty-mount literals route
      through `Mounts.empty/0`.
- [ ] **P3 — `Session.Prompt` + `ProjectMemory`.** Move AGENTS.md I/O and
      prompt composition out of the loop.
- [ ] **P3 — `Session.Usage` struct + defaults.** One home for
      `last_input_tokens` semantics.
- [~] **P3 — Session storage decision (Section 4b).** ADR 020
      (`docs/source/decisions/020-session-storage.rst`, *Proposed*)
      settles the direction: per-session SQLite within a selectable
      store, agent view + immutable display view as separate tables;
      R0 (session management is a first-class surface) leads it.
      Slice 1 shipped: the TUI picker now shows storage footprint per
      session and a total, filters live, toggles this-dir/whole-store,
      and bulk-deletes the visible set (delete-by-directory). `Store.list`
      entries carry `:size` and `:scope_root`. Not yet done: the engine
      change, store selection (`--store`/`AGENT_STORE`), export/import,
      migration of existing blobs. The opencode objection was an API
      objection — missing verbs — which this slice addresses before any
      format change.
- [ ] **P4 — Split `tui.ex` along its own comment sections**; single state
      struct definition.
- [ ] **P4 — `TranscriptView.metrics/…`.** One home for pane geometry; render,
      clamp, hit-test and status all use it.
- [ ] **P4 — Remove `project_dir_for_test` from the production path.**
- [ ] **P4 — Replace `test_mode?` branches with injected behaviours** where it
      has already let bugs slip.

---

# TODO — dog-fooding blockers (urgent)

Found by using the TUI on real work. None of these are architectural; all six
make the tool annoying enough to avoid, which is worse than a bug. Ordered as
they were reported, not by leverage. Root causes below were read from the tree
as reviewed; where a mechanism is not yet pinned, that is said plainly instead
of guessed.

- [x] **B1 — No visible cursor in the input field.**
      Fixed: `input_widget/1` now sets
      `cursor_style: %Style{modifiers: [:reversed]}` explicitly (and
      `cursor_line_style: %Style{}` deliberately — a reversed current char
      is enough; a full-line highlight is noisy in a multi-line composer).
      Root cause was as diagnosed: an empty struct default overwrote
      tui-textarea's own REVERSED default through the always-encoded
      bridge. The upstream API gap ("unset" vs "empty") remains noted for
      a dependency fix; the app-side behavior is correct now. New
      `tui_cursor_test.exs` asserts the widget `render/2` builds carries
      the reversed modifier (the text buffer has no cell attributes).

- [ ] **B2 — Shift+Enter does something strange; typed text disappears.**
      PARTIAL, and the partial attempt introduced a regression
      (`UI_TRACK_A_REVIEW.md` §B). What holds: `:shift` is a real event
      modifier through `Bridge.translate/2` → `Keymap`, `shift+enter` is
      an `insert_newline` (ADR 011, amended), the wire encodings are
      pinned by `tui_shift_enter_test.exs`, and dead `UI.AltDecode` is
      deleted. What does NOT hold: `Keymap.matches?/2` is exact on
      `:mod`, so mapping every shifted special to `:shift` **unbound**
      `shift+tab`, `shift+page_up` and `shift+page_down`, which worked
      before (they now fall through to the raw-textarea path). The
      underlying B2 symptom — "typed text disappears" — is the
      two-authorities bug, still open:
      - **ctrl-j** is declared `:insert_newline` but falls through to the
        crate, which runs `delete_line_by_head` (typed line wiped).
      - **ctrl-u** is declared `:kill_line` but the crate runs `undo`.
      Of the 19 actions `Keymap` declares, `dispatch_input_key/3` handles
      10; the rest are decorative. The real fix is "classify then drop"
      (never forward the raw event), which needs its own ADR — see the
      new P2 item below.

- [~] **B3 — No mechanism to attach or select files in the message field.**
      Not started (Track C). The design in the finding stands: an `@`
      word-start trigger reusing the picker/menu surface, sourced from
      `Core.Tools` under `Tools.scope/1` + `Mounts`.

- [x] **B4 — Hard to tell whether I am in build or plan mode.**
      Addressed with the `UI.Styles` work. The sidebar is retitled
      `" status "` (it holds session/effort/token data, not agent slots)
      and now carries an agent BADGE; while a turn is in flight the
      RUNNING and NEXT agents are both shown (they can differ — Tab only
      changes the next turn's agent), and when idle only the next agent
      shows (no stale running label). Identity is one `Styles.badge/2`
      vocabulary across the input footer, the message-box footers and the
      panel. New `styles_test.exs` and the identity tests in
      `tui_agent_test.exs`.
      Decision recorded (user, on B6): build/plan is NOT a filesystem mode
      — read-only is not "plan" (build legitimately writes `.git/` etc.),
      it is a SIGNAL to the agent ("please plan, no real code changes").
      So no distinct mode chrome is added; identity stays a badge. The
      remaining work is the plan *definition* (B6), not a mode.

- [ ] **B5 — The input field does not auto-wrap.** Not started (Track C).
      Symptom: a long line runs off the right edge and you cannot see what you
      typed (and the box does not grow, because it grows per *line*).
      Root cause, corrected: there is **no `wrap` field to set.** The
      `%Textarea{}` struct is `state, style, cursor_style, cursor_line_style,
      placeholder, placeholder_style, line_number_style, block`
      (`deps/ex_ratatui/lib/ex_ratatui/widgets/textarea.ex:85-93`) — an earlier
      note in this review claimed a `wrap` field existed and was simply unset;
      that was wrong, `wrap` exists only on `Paragraph`/`Markdown`/`CodeBlock`
      (`bridge.ex:76`, `:400`, `:416`, and no textarea case). Upstream
      `tui-textarea` renders per logical line with a viewport that scrolls
      horizontally; soft wrap is not implemented in the crate we depend on.
      `input_height/1` (`tui.ex:67-74`) measures `textarea_line_count/1`, i.e.
      newline count, so wrapping would also have to feed the height math
      (the measure/render agreement rule this file already lives by).
      Fix direction: choose one, explicitly — (a) soft-wrap in our own render
      layer: pre-wrap the value to the input width and map cursor
      row/col ↔ wrapped display position (the honest fix, but it is a real
      text-layout component and it must also drive `input_height/1`);
      (b) patch/vendor the textarea widget upstream to wrap and report wrapped
      height (contributes the fix where it belongs, slower to land);
      (c) accept no wrap and give the input a horizontal scroll indicator so at
      least "there is more text to the right" is visible. Do not do (c) alone —
      the symptom is losing sight of your own text.

- [~] **B6 — Plan mode is useless in its current configuration.**
      Direction settled (user decision), implementation pending. Build/plan
      is a SIGNAL to the agent, not a sandbox/mode state: read-only is not
      "plan" (build legitimately needs `.git/` writes), so the fix is the
      plan *definition* (what tools it gets, whether it may write a durable
      plan artifact, whether it needs read-only network/subagents), not
      mode chrome. The original finding text follows.

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

Cross-cutting note for the research pass: B1/B2 are both one missing piece of
vocabulary (cell-attribute default; shift modifier) rather than logic bugs, and
B4/B6 are the same question asked twice (agent identity vs. mode). Doing B1+B4
as a pair with the `Styles` work covers two blockers for the price of one
refactor; B5 is the only one that is genuinely new machinery.

**Status after the Track A pass:** B1 and B4 are done; B2 is partial and
introduced a regression (see below); the `Styles` vocabulary and the dead
`AltDecode` removal are done. B3 (file picker) and B5 (input wrap) remain
in Track C. B6's direction is settled (plan is a signal to the agent, not
a sandbox mode) and needs only the plan definition decided.

### New backlog from `UI_TRACK_A_REVIEW.md` (2026-09-19)

The Track A review found real defects the green suite could not see. The
mechanical ones (A footer position, E separator, F role aliases, G stale
ADRs, H modifier merge, C phantom `badge_list`) are fixed in the same
pass; the two structural ones are recorded here.

- [ ] **P2 — One authority for input events (the real B2).** The input
      pipeline has two authorities: our `Keymap` and the textarea crate's
      own Emacs bindings. `forward_to_textarea/2` passes the **raw** event,
      so whatever the keymap does not intercept is performed by the crate
      with different semantics. Verified live: `ctrl-j` (declared
      `:insert_newline`) runs `delete_line_by_head` — it wipes the typed
      line; `ctrl-u` (declared `:kill_line`) runs `undo`. Of the 19 actions
      `Keymap` declares, `dispatch_input_key/3` handles 10; the other 9
      (`:cursor_home`, `:cursor_end`, `:kill_line`, `:kill_word`,
      `:kill_to_end`, `:cursor_up`, `:cursor_down`, `:cursor_left`,
      `:cursor_right`) are decorative. Fix: `Bridge` classifies each event
      as exactly `{:text, s}` or `{:command, intent}` and the raw event is
      **dropped, never forwarded**; the intent→crate mapping lives in one
      executor whose handled set *is* the keymap's action set. This is an
      architecture cut and deserves its own ADR.
- [ ] **P2 — Modifier fallback lattice in `Keymap.resolve/2`.** The `:shift`
      pass made `shift+tab`/`shift+page_up`/`shift+page_down` `:unbound`
      (they worked before), because `matches?/2` is exact on `:mod`. Fix
      with a **specific-before-generic** fallback (`shift+X` binding wins,
      else the `none` binding, then `:any`), so adding a modifier family
      can never silently unbind the unmodified bindings. Care: a blanket
      "shift falls back to none" must not re-break `shift+enter` (the very
      bug just fixed) — the ordering above is the whole point.
- [ ] **P2 — Action-coverage test.** Assert that every action in the
      `@type action` typespec is actually handled in `tui.ex` (the 9
      decorative actions above would fail it) and that every
      `Keymap` binding resolves to something handled. This single test
      catches both the P2 items and the class behind them.
- [ ] **P3 — `shift+tab` (crossterm `back_tab`) is unbound.** Pre-existing
      (not a Track A regression), same bug class: a shifted key that the
      terminal reports as a distinct code and the keymap never bound. Fix
      alongside the B2 work so the input vocabulary is complete.

---

# UI — styling and visual consistency

**IMPLEMENTED (steps 1-4 of the sequence below).** `CodingAgent.UI.Styles`
now owns roles (`role/1`), badges (`badge/2`), a definition list
(`definition_list/1`), panels (`panel/1`), section headers, chrome fills
and `status_badge/1`. (`badge_list/1` from the original sketch was
dropped: the input footer needs the `you → agent · model` arrow shape,
not a `·`-joined list, so `badge/2` composed inline is the real
primitive.) The ~35 inline `%Style{}`
sites in `tui.ex`/`transcript_view.ex` are gone (only genuinely-empty
styles and the `Styles` module itself remain); box footers and the input
footer use role-styled identity; the sidebar is a `definition_list` with
a truthful `" status "` title and agent badges. `styles_test.exs` covers
the vocabulary. Not done: a swappable theme (step 5 — deliberately, no
config surface is wanted yet).

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

Layout (`render_main/2`, `tui.ex:1810-1861`):

```
┌─ sidebar (right) ─┐
│                   │   transcript (middle, reading measure)
│                   │
│                   │   ┌─ input box ────────────┐
│                   │   └── you → plan · glm-5.3 ─┘
│                   │
└───────────────────┘   status row (bottom, full width, 1 line)
```

- The status row is split off first, full width, at the very bottom
  (`tui.ex:1820-1824`), while the input box is only reading-measure wide
  (`tui.ex:1840-1844`). So the status is visually detached from both the input
  and the transcript.
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
is asked *at the input box*. Put it on the input box's top border, opposite the
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

This slots into the earlier UI sequence, after `Styles` exists:

1. `Styles.status_badge/1` + role colors; move the glyph/color map out of
   `status_widget_plain/1`.
2. Move the status onto the input box's top border (A); keep a provisional
   bottom row only if transcript-visible status is wanted.
3. Move scroll diagnostics behind a debug toggle (D).
4. Add the `subscriptions/1` spinner + `last_activity_at` tracking (C.1, C.2);
   this is the first real animation and the template for any future one.
5. Add the core `{:tool_started, name}` event so the spinner can name the tool
   and its elapsed time (C.2). Pairs naturally with the `Events` module todo.
6. Glyph passes on dialog / transcript severity / picker (E).

Dependency note: step 5 touches core, so it should land with the `Events`
module work (P2 in the TODO) rather than as a one-off. Steps 1–4 are pure UI
and can land independently. The spinner is worth doing regardless of `Styles`
maturity — it is the single biggest perceived-responsiveness win here, because
it turns "the app might be hung" into "the tool has been running 38 s".

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
