# Review follow-ups — 2026-09-19 (post Track B)

Findings from reviewing the recent commits (up to and including `6ab37de`,
Track B). None of these are urgent; the first two are small and worth a
near-term follow-up commit while the Track-B context is fresh, the third is
a deliberate-shape note to re-evaluate when the bottom row next changes.

- [x] **F1 — Unbounded atom creation in `Keymap` (`String.to_atom/1`).**
      Fixed: `Keymap` now resolves every action and key name through the
      bounded `Bridge.key_atom/1` vocabulary (mints no atom; unknown names
      resolve to `:unknown_key` and are dropped). Regression test asserts
      the VM atom count is unchanged across a 500-name junk load.
      Pre-existing (entered with `be42340`, ADR 014), *not* a Track-A/B
      regression — recorded because the 5b crash lesson ("atomizing every
      keypress") makes this the same bug class in a config-shaped input.
- [ ] **F2 — `clear_tool_if_done/2` is dead code; `touch/1` nullifies its
      guard.** Real but small: wrong label / reset clock on multi-call
      gate rounds. Introduced in `6ab37de`.
- [ ] **F3 — The bottom status row duplicates the input-border status.**
      Deliberate (provisional per the review's option B), noted so it is a
      known candidate to drop rather than an accident to defend.

---

## F1 — `Keymap` builds atoms from unbounded user input

Where: `lib/coding_agent/ui/keymap.ex`

- `merge/2` (:199) — `String.to_atom(String.replace(action_name, "-", "_"))`
  on every `[keys]` action name from `ui.toml`.
- `to_pattern/1` (:246, :247) — `String.to_atom("ctrl_" <> k)` and
  `String.to_atom(k)` on every key name in a binding spec.

Both run on **user-authored config text** with no vocabulary bound. Every
distinct action name and every distinct key name in a `ui.toml` becomes a
permanent VM atom. Contrast the spec-key paths right next to them:
`to_pattern("alt-" <> k)` and `to_pattern("shift-" <> k)` correctly use
`String.to_existing_atom/1`.

Two inputs, two exposure levels:

1. **`to_pattern/1` is reachable from the keypress-independent config
   load** (`Keymap.load/0` → `merge/2` → `parse_spec/1`), i.e. every TUI
   mount. This is the live path: an edited (or corrupted, or hostile)
   `ui.toml` with many distinct key names creates that many atoms per
   load. The comment in `merge/2` even documents the intent to atomize
   first and validate after ("user config may name an action the atom
   table has never seen — build the atom, then validate membership
   below") — that is the exact order the 5b lesson says not to use.
2. **`merge/2`'s action-name path is the same pattern one line up.** The
   `rescue ArgumentError -> :unknown_action` around it is real but its
   bound is the attacker's patience with distinct names.

Severity and threat model, stated honestly: the config files are the
user's own files (`~/.config/coding-agent/`, project `.coding-agent/`) —
the same trust domain as the store's `binary_to_term` argument — and the
BEAM dies only above ~1M atoms, so a practical exploit needs a *lot* of
distinct names and repeated reloads. This is a **discipline/latent**
finding, not a live bug. The codebase's own precedent (the 5b bridge
crash; the decision that "the atom vocabulary is bounded by the keymap,
not by typing"; ADR 021's input-authority reasoning) is that
user-influenced strings are matched against a bounded vocabulary, never
converted into new atoms.

Fix direction (small, contained):

- `merge/2`: build the candidate atom with `String.to_existing_atom/1`
  (rescue to `:unknown_action`, which already flows to the unknown list).
  The action vocabulary is `Keymap.defaults()`'s keys — all of those atoms
  exist once the module is loaded.
- `to_pattern/1`: same, with a **pre-seeded** vocabulary for the
  synthesized `ctrl_*`/`alt_*` names: build the known chord universe once
  (compile time or first call) from the keys the bridge can actually emit
  (letters + specials: enter, esc, tab, backspace, delete, arrows,
  home/end, page_up/page_down, f-keys …), then `String.to_atom` only
  against that set and reject anything else. A key the bridge can never
  emit would never match anyway, so rejecting is behavior-preserving for
  every real config.
- Pin with a test: a `ui.toml` full of unknown action names and unknown
  key names loads to defaults + the unknown warnings, and
  `:erlang.system_info(:atom_count)` is unchanged by the load.

Related, same module, same fix cost: `Bridge.translate/2` (:80) does
`String.to_atom(code)` per keypress for the bound-letter check — bounded
in practice (single lowercase letters only, so ≤26 atoms ever), but
`to_existing_atom` after the config-load pre-seed makes the whole
pipeline bounded with one idiom.

## F2 — `touch/1` defeats `clear_tool_if_done/2` (multi-call rounds)

Where: `lib/coding_agent/ui/tui.ex` (handler ~:1843, `touch/1`
:1998–2000, `clear_tool_if_done/2` :2004–2007), introduced in `6ab37de`
(Track B).

The handler states the intent and then un-does it:

```elixir
# handle_info({:agent, {:tool_executed, name, content}}, state)
state =
  state
  |> touch()                        # <- sets active_tool: nil unconditionally
  |> Map.put(:transcript, transcript)
  |> ...
  |> clear_tool_if_done(name)       # %{active_tool: name} can never match
```

`touch/1` is:

```elixir
defp touch(state) do
  %{state | last_activity_at: now_ms(), active_tool: nil, tool_started_at: nil}
end
```

By the time `clear_tool_if_done/2` runs, `active_tool` is already `nil`,
so the matching clause `(%{active_tool: name}, name)` is unreachable —
the guard the comment promises ("only clear the in-flight label if it
matches (a round can interleave calls and results)") never fires, and the
non-matching clause is what always executes. Dead code that documents an
invariant the code does not maintain.

The sequence it breaks is a multi-call gate round. `Session.execute_tools/2`
(core, :1165–1174) announces **all** calls of a round before executing
any:

```
tool_started(A), tool_started(B), tool_executed(A), tool_executed(B)
```

Two consequences:

- During A's actual run the status shows **B** ("running B") — all starts
  precede all executions, so the label is the last announced call, not
  the running one.
- At `tool_executed(A)`, `touch/1` clears B's label and resets
  `tool_started_at`, so the status falls back to "thinking" while B still
  runs — the exact interleave case `clear_tool_if_done` was written for.

Impact: cosmetic-to-minor (wrong/missing label and a reset elapsed clock
during multi-call rounds; single-call rounds are unaffected), but it is a
comment/invariant mismatch in freshly shipped code — the kind that
solidifies into assumed behavior.

Fix direction — pick one; option 1 also improves the core event shape:

1. **Root-cause fix (preferred): announce per call, just-in-time.** Move
   the `{:tool_started, name}` broadcast from `Session.execute_tools/2`
   (all-up-front) into `ToolRunner.execute/3`, immediately before each
   call's own execution. Start↔result then interleave correctly
   (`started(A) executed(A) started(B) executed(B)`), the TUI label is
   always the actually-running tool, and `touch/1`'s clearing on a result
   becomes correct for the next call because the next start re-sets it.
   Small core change; the TUI code stays as-is (the dead guard becomes
   reachable and correct).
2. **TUI-only fix:** stop clearing the tool in `touch/1` (keep it to the
   silence clock), and let `clear_tool_if_done/2` plus the existing
   `active_tool: nil` resets at turn start/end own the lifecycle. Less
   faithful to the real sequence, but a two-line diff.

Test to add either way: a two-call round
(`started(A), started(B), executed(A), executed(B)`) asserting the label
reads "running B" during A's execution window (option 1), or at least
that it does not fall back to "thinking" after `executed(A)` (both).

## F3 — The bottom row duplicates the status label (re-evaluate when layout changes)

Where: `lib/coding_agent/ui/tui.ex` — `status_widget_plain/1` (:2967)
keeps `Text.Span.new(badge.label, ...)` in the bottom row while
`status_line_for_input/1` (:2655) already renders the full status (glyph
+ spinner + label + elapsed) on the input box's top-right border.

This is **deliberate, not an oversight**: the review's option B ("keep a
1-line row if transcript-visible status is wanted") and the Track-B
commit message both record the bottom row as provisional. Two notes to
keep it honest:

- The two surfaces can drift: the border title carries the live
  tool/silence detail, the bottom row carries only the static
  `badge.label` (from `status_badge/2`), plus the esc hints and the
  debug-gated diagnostics. That split is defensible (detail at the input,
  glanceable summary at the screen bottom), but it is two renderers of
  one concept again — the pattern the review keeps flagging. If they ever
  need to differ further, make the bottom row consume
  `Styles.status_line/5` (a label-only variant) instead of
  `status_badge/2` directly, so there is one source for the label text.
- The row's remaining unique content after Track B is: session id, esc
  hints, debug diagnostics. If/when the status-on-input pattern is
  confirmed in use, dropping the duplicate label (or the whole row,
  folding the hints into the input footer) frees a full terminal row and
  reduces `status_widget_plain/1` to near-nothing. Cheap to do whenever
  the layout is next touched; nothing to do now.

## Provenance note (resolved 2026-09-19, AGENTS.md)

An earlier draft of this review observed a "dangling `.. important:` RST
directive inside AGENTS.md" and an empty staged blob. Both were
**transient states of a half-finished edit in the OTHER worktree**
(`devel`), which this session can read but not write (files there are
outside the session scope). The author has since finished that edit:
`AGENTS.md` at `devel` (commit `6d75c58`) is the intended ~19-line version
(title, `> [!IMPORTANT]` alpha note, the three implementation rules,
the two explicitly non-goals). No defect; nothing to fix. The underlying
workshop note — shared docs live in `devel`, this review runs in the
`mjansen` worktree, so in-progress edits there are invisible until
committed — is recorded here because it caused the same confusion twice
(`code_review.md` drift, then this).

---

*From the full review of commits `cf1fad2…6ab37de` (2026-09-19). F2 is the
only one with user-visible behavior attached; F1 is the same lesson class
the 5b bridge crash taught; F3 is recorded so the provisional decision
does not fossilize.*