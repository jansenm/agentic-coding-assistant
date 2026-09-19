# Review — Track A working tree (B1, B2, B4 + `UI.Styles`)

Reviewed as an **uncommitted working tree** on top of `ebaef71` (`devel`).
Nothing in the tree was edited; probe scripts were created outside the
reviewed files and deleted again.

Re-verified at the end of the review against the tree *as it stood then*
(the tree grew during the review — see "Concurrency note" below); every
finding below was re-confirmed after that growth.

## Scope

Changed/new in the reviewed tree:

```
 M code_review.md                       (+133)
 D lib/coding_agent/ui/alt_decode.ex            (-64)
 M lib/coding_agent/ui/bridge.ex                (+25/-9)
 M lib/coding_agent/ui/keymap.ex                (+40/-12)
 M lib/coding_agent/ui/transcript_view.ex       (+49/-36)
 M lib/coding_agent/ui/tui.ex                   (+125/-38 hunks; 511 +/- total)
 D test/coding_agent/ui/alt_decode_test.exs     (-48)
 M test/coding_agent/ui/bridge_test.exs
 M test/coding_agent/ui/tui_agent_test.exs
 M test/coding_agent/ui/tui_visual_test.exs
 ?? lib/coding_agent/ui/styles.ex               (232)
 ?? test/coding_agent/ui/styles_test.exs        (104)
 ?? test/coding_agent/ui/tui_cursor_test.exs    (33)
 ?? test/coding_agent/ui/tui_shift_enter_test.exs (95)
```

What it does: adds `CodingAgent.UI.Styles` (roles, `badge/2`,
`definition_list/1`, `gap/0`, `panel/1`, `section_header/1`, `chrome/0..1`,
`chrome_bg/0`, `status_badge/2`); replaces ~35 inline `%Style{}` sites in
`tui.ex`/`transcript_view.ex` with role lookups; sets
`cursor_style: %Style{modifiers: [:reversed]}` on the input textarea (B1);
makes `:shift` a real modifier through `Bridge.translate/2` → `Keymap` and
binds `shift+enter` → `insert_newline` (B2); retitles the sidebar panel
`" agent "` → `" status "` and gives it agent badges (B4); deletes
`UI.AltDecode` + its test; `transcript_view.ex` footers now return
role-styled `Text.Line`s.

## Gate status at review time

```
mix compile --force                     52 files, no warnings
mix compile --warnings-as-errors        clean
mix test                               545 passed
mix format --check-formatted            clean (exit 0)
```

Baseline checks all green. The findings below are **not** build or test
failures — they are behaviour and consistency defects that the current
suite cannot see, which is itself part of the finding.

---

## Verdict

The direction is right and `Styles` is a real improvement: the vocabulary
exists, the ~35 scattered `%Style{}` literals are gone, and B1 is
genuinely fixed with an honest test. But **two of the three "fixed"
blockers introduce regressions**, and one of the four items reported as
done (`badge_list/1`) does not exist in the code at all.

Common root cause: the input event pipeline still has **two authorities**
— our keymap and the textarea crate's own Emacs bindings — and this pass
added a third inconsistency on top: a modifier now reaches the keymap, but
only *one* shifted key is bound. Every finding below is a facet of that one
missing invariant.

---

## Verified good

- **B1 fixed.** `tui.ex:2477` sets
  `cursor_style: %Style{modifiers: [:reversed]}`. Probed cell-by-cell: the
  old widget produced `mods=[]` at the cursor cell, the new one
  `mods=[:reversed]`. `tui_cursor_test.exs` asserts the honest thing (the
  widget `render/2` builds, since the char buffer carries no cell
  attributes).
- **B4 renders.** "build running" / "plan next" confirmed in the rendered
  buffer; the panel title is truthfully `" status "` and the panel really
  does hold session/effort/token data, so the rename is correct.
- **Style consolidation is real.** 38 inline `%Style{}` literals removed
  from `tui.ex`; the 4 remaining are intentional (`cursor_style`,
  the deliberately empty `cursor_line_style`, one empty `style: %Style{}`).
  `transcript_view.ex` has none left.
- **`AltDecode` deletion is defensible.** At HEAD it had **zero call sites
  in `lib/`** — only its own test and one docstring mention in
  `keymap.ex:12`. The CLI line mode is `IO.gets` and never used it.

---

## A. Regression — the agent-box footer moved from bottom-right to top-left

`TranscriptView.agent_block/2` (`transcript_view.ex:221`) used to build the
block with:

```elixir
title_position: :bottom, title_alignment: :right, title_style: %Style{fg: :dark_gray}
```

It now delegates to `Styles.panel/1` (`styles.ex:158`), which **accepts
neither `:title_position` nor `:title_alignment`** and silently leaves the
`%Block{}` defaults. Re-verified in a 34×4 cell session, current tree:

```
NEW   ╭you → build─────────────────────╮
      │hi                              │
      │                                │
      ╰────────────────────────────────╯

OLD   ╰─────────────────────you → build╯
```

Affects the composer, every user box and every assistant box (three call
sites: `tui.ex:2096`, `:2117`, `:2480`). Nothing failed because the tests
only assert `buffer =~ "you → build"` — substring presence, position-blind.

Related, same path: `Styles.panel/1` has no `:border_type` option, and
`tui.ex:2966` reaches around it with
`%{Styles.panel(...) | border_type: :double}`, which contradicts the
module's own doc ("Owns border type/color/placement"). `styles_test.exs`
asserts only `border_type == :rounded`, i.e. it pins the default and never
the caller's need.

**Fix:** add `:title_position`, `:title_alignment` and `:border_type` to
`panel/1`, or keep passing them in `agent_block/2`. Then add one
position-asserting test (`rows |> List.last() |> String.contains?(footer)`),
which is the assertion that would have caught this.

## B. Regression — the `:shift` change unbinds every other shifted special key

`Keymap.matches?/2` (`keymap.ex:122-124`) is exact on `:mod`, and the only
new binding is `shift+enter` (`keymap.ex:61`). `Bridge.key_event/4`
(`bridge.ex:112`) now maps *any* shifted special to `%{mod: :shift}`, so
every other shifted special resolves `:unbound` and falls through
`dispatch_input_key`'s wildcard `_ ->` (`tui.ex:1334` ff.) to
`forward_to_textarea/2` (`tui.ex:1510`), which forwards the **raw** event.

I compiled HEAD's `bridge.ex`/`keymap.ex` under renamed modules beside the
working tree and diffed the *effective route* (handled action vs. raw
fall-through), re-verified against the current tree:

| event | HEAD | now | route change |
|---|---|---|---|
| `tab` + shift | `:switch_agent` | `:unbound` | **HANDLED → raw→textarea** |
| `page_up` + shift | `:scroll_up` | `:unbound` | **HANDLED → raw→textarea** |
| `page_down` + shift | `:scroll_down` | `:unbound` | **HANDLED → raw→textarea** |
| `up` + shift | `:cursor_up` | `:unbound` | same route, new `:mod` |
| `home` + shift | `:cursor_home` | `:unbound` | same route, new `:mod` |
| `end`/`delete` + shift | `:unbound` | `:unbound` | same route, new `:mod` |
| `enter` + shift | `:insert_newline` | `:insert_newline` | intended fix |

Live through the TUI (inject_event), current tree:

```
plain page_up        -> scroll_offset=5
shift+page_up        -> scroll_offset=0     (no longer scrolls)
plain tab            -> next_agent: nil -> "build"   (still switches)
back_tab + shift     -> next_agent unchanged, value="    "  (inserts 4 spaces)
typed "abcdef" -> plain left x2 -> shift+right x2 -> X
                     -> "abcdX"   (the shift+arrows created a SELECTION; X replaced it)
```

So a shifted arrow now silently becomes a text-selection gesture that eats
the next keystroke, and shifted paging silently stops scrolling.

Two further facts worth recording:

- **The crate ignores `:shift` for most keys.** Verified against the raw
  NIF (`textarea_handle_key/3`): `up+shift` moves exactly like `up`,
  `home+shift` like `home`, `delete+shift` deletes like `delete`,
  `page_up+shift` is a no-op. Only *horizontal* movement treats shift as a
  selection gesture. The new `:mod` therefore changes behaviour on keys
  where the crate "agrees" by accident and misbehaves where it doesn't.
- **`shift+tab` on a legacy terminal does not arrive as `tab+shift` at
  all.** crossterm reports `back_tab` (`deps/ex_ratatui/native/ex_ratatui/src/events.rs:75`),
  and `:back_tab` was **already unbound at HEAD** (`:switch_agent` is only
  reachable via plain `tab`). So the observed "shift+tab inserts 4 spaces"
  is pre-existing, not introduced here — but it is the same bug class and
  should be fixed in the same pass.

This is exactly the B2 pattern the change set out to kill, reproduced one
key over: **the keymap and the textarea disagree about the same keypress.**

**Fix:** a modifier fallback lattice (`:shift` → `:none` → `:any`) resolved
in `Keymap.resolve/2`, instead of per-key bindings. Then adding a modifier
family can never silently unbind the unmodified bindings.

## C. `Styles.badge_list/1` is documented but does not exist

Re-verified: `function_exported?(Styles, :badge_list, 1) == false`.
Exports are exactly:

```
badge/2, chrome/0, chrome/1, chrome_bg/0, definition_list/1, gap/0,
panel/0, panel/1, role/1, section_header/1, status_badge/1, status_badge/2
```

`code_review.md:450` ("badges (`badge/2`, `badge_list/1`)"),
`code_review.md:527` (the sketch), `code_review.md:607` (the sequencing
step) and the new "IMPLEMENTED" note all claim it. `styles_test.exs` does
not test it. Either implement it or strike it from code docs and the status
note — as written, the review document asserts an API the tree does not
have.

## D. The real B2-class bug — two editors, one keystroke

`forward_to_textarea/2` passes the **raw** event, so the crate's own
bindings win for everything the keymap does not intercept. Verified against
the raw NIF *and* live through the TUI, cursor at the end of a typed line:

| key | keymap claims | crate actually does | live result |
|---|---|---|---|
| `ctrl-j` | `:insert_newline` | `delete_line_by_head` | `"hello world"` → **`""`** |
| `ctrl-u` | `:kill_line` | `undo` | typed text **wiped** |
| `ctrl-k` | `:kill_to_end` | `delete_line_by_end` | works *by coincidence* |
| `ctrl-w` | `:kill_word` | `delete_word` | no-op at end of line (accidental pass) |

Structural root cause: of the ~20 actions `Keymap` declares
(`keymap.ex:22-45`), `dispatch_input_key` handles **10**. `:cursor_home`,
`:cursor_end`, `:kill_line`, `:kill_word`, `:kill_to_end`, `:cursor_up`,
`:cursor_down` … all fall to the wildcard `_ ->` and are really performed
by the crate. The keymap's claims for those keys are **decorative**, so any
divergence is invisible until a user hits it. (Re-verified: `ctrl_u` →
`:kill_line`, but no `:kill_line ->` clause exists in `tui.ex`.)

`ctrl-j`/`ctrl-u` are pre-existing at HEAD — this change did not introduce
them — but this review is where they must be recorded, because they *are*
the reported B2 symptom ("typed text disappears"). Marking B2 `[x]` as
"fixed at the vocabulary level" overstates the state of the tree.

**Fix (the one that deletes the class, not the instance):** the bridge
classifies each event as exactly `{:text, s}` or `{:command, intent}` and
the raw event is **dropped**, never forwarded. Intent → crate mapping lives
in one executor, and `dispatch_input_key`'s handled set *is* the intent set.

## E. Regression — `definition_list/1` lost the label/value separator

`definition_line/1` (`styles.ex:128`) concatenates label and value with no
separator. Re-verified in-render:

```
|sessiontui-259|
|effortdefault|
|compacts at180.0k tok|
|context0 (0% win)|
```

HEAD put the value on its own line (`"effort: default"`), unambiguous at the
sidebar's 36 columns. This is a visible readability regression in the
exact panel B4 was meant to improve. Note `styles_test.exs` asserts the
spans, so it passes on the broken rendering; there is no rendering test for
the sidebar rows.

## F. Role collisions contradict the module's own charter

`styles.ex:52-62`, re-verified values:

```
:muted      %Style{fg: :dark_gray}            # hint text
:model      %Style{fg: :dark_gray}            # model identity  == :muted
:info       %Style{fg: :dark_gray}            # == :muted
:accent     %Style{fg: :cyan, modifiers: [:bold]}   # focused chrome
:agent      %Style{fg: :cyan, modifiers: [:bold]}   # == :accent
:reasoning  %Style{fg: :dark_gray, modifiers: [:italic]}
```

The moduledoc states "One meaning per color role". `:model` and `:accent`
are arguably *intentional* aliases (model text is muted; accent borrows the
agent hue) — but that intent is written nowhere, so the next author will
"fix" one of them and move chrome colours by accident. One sentence per
alias in the moduledoc removes the trap. Note also that the `:value` /
`:muted` distinction is invisible in the rendered sidebar, since both land
in the same line and are hard to tell apart at 36 columns.

## G. ADRs are stale as a direct result of this diff

- `docs/source/decisions/012-tui-backend.rst:88` — "ADR 011's ESC-prefix
  decoder becomes unnecessary for the TUI path (**kept for the CLI
  line-mode harness**)". The decoder was deleted in this tree; the harness
  is `IO.gets` and never used it. The stated justification is now false.
- `docs/source/decisions/011-keymap-input.rst:55` — "``ctrl-enter``/
  ``shift-enter`` → **send**, *when the terminal can distinguish them*".
  `keymap.ex:61` now binds `shift+enter` → **insert_newline**. The ADR
  table and the keymap disagree, and the keymap is the data-of-record
  (ADR 011's own claim).

Both should be amended in this commit, since the commit is what falsifies
them. `tui_shift_enter_test.exs` documents the new intent well; the ADR
does not.

## H. Minor

- `tui.ex:2800` — `Map.put(badge.style, :modifiers, [:bold])` for the
  status glyph **replaces** rather than merges modifiers. Harmless today
  (the roles it can receive have no other modifier) but a trap the moment a
  role gains one; `%Style{badge.style | modifiers: ...}` has the same
  problem. Either merge or comment why replacing is correct here.
- Duplicate `alias ExRatatui.Text` in `tui.ex` (lines 32/33 at HEAD) —
  pre-existing, not introduced by this diff.
- `code_review.md` new text cites `tui.ex:2338-2353`, `:2412-2513`,
  `:2671-2715`, `:2846`, `:490-567` etc. The `tui.ex` edits shifted most of
  these; several references in both the new and the old sections now point
  at the wrong lines. (The file grew again during the review — see below.)
- `docs/source/explanation/memory.rst` (+71/-…) and the untracked
  `docs/source/decisions/020-session-storage.rst` are in this working tree
  but are unrelated to Track A. If 020 is not meant to land here, it will
  ride along inside a UI commit.

---

## Concurrency note

While this review was being written, the working tree changed underneath
it: `lib/coding_agent/core/session/store.ex` (+34), `test/coding_agent/core/store_test.exs`,
a new `test/coding_agent/ui/tui_picker_test.exs` (+116), and `tui.ex` grew
from ~2881 to 3005 lines. All findings above were re-verified **after** that
growth and still hold (panel defaults, `badge_list` absence, definition-list
rendering, role collisions, shift resolution table, ctrl-chord claims). Line
numbers for `tui.ex` in this document reflect the tree at re-verification.
Recommendation: land Track A as its own commit before further unrelated UI
work, and re-run the position/route probes if the event pipeline changes
again.

---

## What I would do next (smallest change that removes the class)

1. **A (footer position):** three options in `Styles.panel/1`; one
   position-asserting render test.
2. **B (shift fallback):** modifier fallback in `Keymap.resolve/2`, plus a
   test that every action in the `@type action` typespec is executed in
   `tui.ex` (that single assertion catches both A and D).
3. **D (one authority):** classify-then-drop in `Bridge`/`dispatch_input_key`
   so raw events are never forwarded; move the crate mapping into one
   executor.
4. **C/E/F:** implement or delete `badge_list/1`; restore the separator;
   document the role aliases.
5. **G:** amend ADR 011 and ADR 012 in the same commit as the code.

Items 1 and 2 are self-contained and could land immediately so the tree
stops carrying known regressions; 3 is the redesign and deserves its own
ADR.
