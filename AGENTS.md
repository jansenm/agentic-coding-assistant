<!--
SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>

SPDX-License-Identifier: MPL-2.0
-->

# Coding Agent

This repository contains the ongoing implementation of an agentic coding assistant
harness. 

> [!IMPORTANT]
> The implementation is still in alpha-phase.

## Rules

During the implementation consider the following rules as the most important:

* Adherence to the design principles
* Minimizing code duplication
* Separation of concerns on a module level

The following principles do not matter at this point:

* Backwards compatibility. (*The software is unreleased*)

## Merging: squash, always

A pull request is merged as **one commit** — `gh pr merge --squash`, never a
merge commit and never a rebase merge. The commits on the branch are the review
record; `devel`'s history is one commit per change. The squash commit is the
record that survives, so its subject follows the house style and its body
carries the why, what was verified, and `Fixes #n` for each issue the PR closes.
The merged branch is left in place (`delete_branch_on_merge` is off).

## Maps become structs when the shape is known

A record whose keys are known at compile time is a **struct**, not a bare map.
Owner decision (2026-11-01): wherever it makes sense, convert — the default is
the struct, and a map has to justify itself.

What a struct buys that a map does not:

* a mistyped key is a compile error, not a `nil` at runtime;
* `%{m | k: v}` fails loudly on a field that is not there, while a map update
  quietly works on a key nobody declared (`Map.put(state, :last_pane_rect, …)`
  in `ui/tui.ex` is such a field: written and read, never declared);
* `Map.get(m, :k, default)` — the "the field may not exist" idiom — stops being
  needed, and with it the ambiguity between *absent* and *empty*;
* the record gets a name in specs (`@type t :: %__MODULE__{}`), in pattern
  matches (`%Tabs.Child{}`), and in every `IO.inspect`, instead of an anonymous
  `%{agent: …, stream: […], …}` that a reader has to reconstruct.

**The exception is a dictionary**: keys not known ahead of time — a keymap
(`action => patterns`), permission entries (`tool => pattern => decision`), a
path→value store. Those stay maps and their `@type` says so (`%{K => V}`).

**A record that crosses a persistence or wire boundary** (a session snapshot,
a `term_to_binary` payload) is upgraded with `new/0` + `from_map/1`: heal the
old shape at the EDGE where it is loaded, never in the middle of the code.
`Core.Session.Usage.from_map/1` is the precedent — it turned `Usage` from a
map into a struct without a snapshot migration.

`TODO.md` ("Maps → Structs") carries the list of what is still a map, with the
measurements. Keep it current when you convert one.

## One repo, two worktrees — work in the one your context names

This repository is checked out as **linked worktrees sharing one history**
(`agentic-coding-assistant` and `agentic-coding-assistant-mjansen`). Both are on
this filesystem at the same time, and they do **not** see each other's work: an
edit, a new file and the git index live in the worktree, not in the repository.

**Work in the worktree your context names** — the `Working directory` and
`Git: linked worktree, <branch>` rows of your env block — and nowhere else. Do
not `cd` into the sibling checkout, not even to look: a tool that writes there
writes into another writer's tree, and the harness you are running beside works
in it *at the same time*. Two harnesses have already lost each other's edits
exactly this way.

If your context does not name a worktree, ask before writing.

## Tests and their log output

A test that triggers a warning must capture and assert it — `capture_log(fn ->
… end)` plus `assert log =~ "…"` — so the expectation is in the test and a
moved warning fails it. A test that only trips a warning by accident (an
uncataloged test model, a fixture that needs a real session) declares what it
needs instead (`CodingAgent.TestScope.declare_window!/1`).

No run-wide mute (`ExUnit.start(capture_log: true)` was considered and
rejected): the suite's log output is the signal for a warning nobody
expected, and a test that warns without saying so is the noise that made a
green run take two `mix test` invocations to read.

## The binary's payload is the host's, and it is cached

`MIX_ENV=prod mix release` (Burrito, ADR 048) writes
`burrito_out/coding_agent_linux`. Two things about that build look exactly
like application bugs and are not. Both have already cost a day in the
gitspace checkout; read this before "fixing" a NIF load error.

**The payload must be this host's.** Burrito's default ERTS is musl and it
treats **every** Linux target as a cross-build, recompiling NIFs with
`zig cc … -shared`. Both NIFs here are host-built glibc objects — `exqlite`
and `ex_ratatui` (Rust, ADR 035) — so the default payload fails at load time
(`Error loading shared library libgcc_s.so.1: Exec format error`,
`__memmove_chk: symbol not found`, or, after the `zig cc` link,
`/lib64/libc.so: invalid ELF header`). The two lines that make it right are
in `mix.exs`: `skip_nifs: true`, plus `custom_erts:` naming the **exact**
running ERTS (`"erts-#{:erlang.system_info(:version)}"`), not the OTP root —
the root holds several `erts-*` and Burrito takes the first.
`burrito_out/coding_agent_linux maintenance meta` prints what a payload
actually contains; ask it before theorising about the app.

**The payload is extracted once per version and reused.** Burrito unpacks
under `$XDG_DATA_HOME/.burrito/coding_agent_erts-<erts>_<version>` (hence
`~/.local/share/.burrito/…`), keyed by app version. Rebuild the wrapper
without bumping `version:` and you keep running the payload from the
previous extraction, so a real fix looks like no change at all. Delete that
directory — or bump the version — before testing a rebuilt binary.

Diagnostics: `maintenance meta` works through the wrapper, `eval` does not —
it starts the TUI and waits for keys, which on a non-tty stdin is a hang. Run
expressions through the extracted payload's own
`bin/coding_agent eval …` instead.

The consequences are deliberate, not accidents: the artefact is glibc and
x86_64 only (musl or multi-platform waits on cross-compiling `ex_ratatui`,
ADR 035), and Burrito 1.6.0 cannot run a TUI at all — it pipes the BEAM's
stdout, so OTP disables its tty backend and the app can draw but cannot read
a key. Stay on 1.5.0 (ADR 048; upstream is archived on 2026-11-30, so the pin
is a pin on a known-good wrapper, not a wait).

## Feedback from the agent (wanted)

This repository is both the harness and the product: the program an agent
is running in is the code it is reading. An agent working here is therefore
also the first user of the interface, and its observations are wanted.

Say so — plainly, as part of the answer — when something gets in the way:

* a tool that returns something you cannot use, or that you had to call a
  second time to work around;
* a piece of context you were missing (which directory, branch, version,
  mode or status you are in);
* a prompt or agent line that over-generalizes and pushes you toward the
  wrong behaviour;
* a permission, sandbox or confirmation step that surprised you;
* a process or tool that deleted, overwrote or lost work.

Name what you expected, what you got, and what you would change. Keep it to
the interface you are working *through*; judging the code itself is a review
task, not a side note.

Review findings and harness feedback both live as **issues on the GitHub
project** — one issue per finding, the `N…`/`P…`/`I…` number in the title is
the ID (`review-process.md` has the convention). Say it in your answer, and
open the issue (or the owner will, if it came up in conversation). Do not
start a new `review.md`: the issue is the record, and closing it is the
closure.
