# Review process — how a review record is handed over and triaged

**Status: provisional.** There is no real review process yet. This repository is
dogfooding its own agent, so "the agent reviews the commits" and "we run the
product" are currently the same activity, and this file only records the
convention that grew out of that — enough to stop losing work. When there is a
real process, this file is replaced by it.

## Consolidated 2026-10-04: there is ONE review file now

A record per run meant that "what is still open" was a search across six
files, with the closed ones kept as `.triaged` archives beside them even
though the commits are the record. Open findings from every record (and the
harness-feedback points) now live in **`review.md`**, one entry per finding,
anchored to a symbol, its introducing commit and the revision it was read at.
Closed findings are deleted from it; a short table at the foot maps an old
`N…`/`P…` to its fixing commit so a cited number still resolves.

Rules that survive:

* A finding has a **number** (`N…`, ascending, never reused) or a feedback
  point (`P…`).
* A finding carries an **Ort** (a symbol, never a line number) and an
  **Eingeführt** (the commit that last wrote the offending line). The record
  as a whole carries a **Stand** — the revision it was read at. Three
  questions, three fields; see "Three fields, three jobs" below.
* **Do not `rm` a finding while it is open.** Closing one — moving it to the
  commit table — is the owner's call (same as any deletion).
* A record that is fully worked off is **deleted**, not renamed: its fixes
  are commits, and `review.md`'s table names them. (The old
  `review-<subject>.md.triaged` convention is retired; its `## Closed by`
  line named a commit that did not exist — see step 3 below.)


## Roles

| Role             | Who                                   | Writes to                          |
|------------------|---------------------------------------|------------------------------------|
| **Review agent** | the agent that reviews a commit range | `review.md`, in the review worktree |
| **Triage agent** | the agent that works the findings off | `review.md` (close) + `TODO.md`    |
| **Owner**        | the human                             | decides scope; commits; deletes    |

The review worktree is `agentic-coding-assistant-mjansen`, the main worktree is
`agentic-coding-assistant`. The triage agent reads `review.md`, works the
findings off, and commits — the review agent never does.

**Work in the worktree your context names, and nowhere else.** The two are
linked worktrees of ONE history, on the same filesystem: they do not see each
other's edits, and another harness is usually live in the other one. A `cd` into
the sibling checkout (or an absolute path into it) writes into a second writer's
tree. The worktree you were started in is named in the env block's
`Working directory` row; that is the answer, and there is no case where reaching
across is right.

**"The owner commits" is a rule about committing, not about writing.** An agent
in build mode EDITS `review.md` and `review-process.md` like any other file; the
owner reviews and commits them afterwards. Marking a finding closed, adding a
row to the commit table, and writing the triage prose are all agent work. Only
the commit is the owner's.

(Why this sentence exists: a build agent answered one of those tasks with a
proposal instead of an edit — the mode in force was read-only, and the agent
explained the restriction to itself out of the "owner commits" line. If the
mode is ambiguous, WRITE and let the policy refuse: a refused write costs one
turn, a plan the owner did not ask for costs the delivery. The mode itself is
the harness's to broadcast — see P23 in `review.md`.)

## The record

- **One file: `review.md`**, in the review worktree, **untracked** (the owner
  commits code changes, not review artefacts). One place for everything open.
- Findings are numbered `N1, N2, …`, ascending, **never reused**. A new review
  continues the count; it does not restart.
- The record names the revision it was read at (**Stand**); each finding names
  an **Ort** (a symbol — never a line number, which is void after the next
  rebase) and an **Eingeführt** (the commit that last wrote the offending
  line). See the next section.
- **Deleted when closed**, not archived. A short table at the foot of
  `review.md` maps the number to its fixing commit, so a cited `N…` still
  resolves.

## Three fields, three jobs

`Stand`, `Ort` and `Eingeführt` are not synonyms, and treating them as one is
how a whole review round came to anchor on a docs commit from the day the
review was written instead of the months-old line that carries the bug. Three
questions, three commands:

| Field | Question | Who fills it | Command |
|-------|----------|--------------|---------|
| **Stand** | which revision did I read? | the reviewer, **once**, at the top of the record | `git rev-parse --short HEAD` + branch + `git log -1 --format=%ad --date=short`, and say "dirty" if the tree was not clean |
| **Ort** | where do I find it now? | the reviewer, per finding | the module + symbol (function, attribute, prompt section) |
| **Eingeführt** | how old is the bug? | whoever works the finding off | `git blame -L <line>,<line> --date=short -- <path>` |

**Blame the offending line — not the file, not the symbol.** `git log -1 --
<path>` almost always names a commit that had nothing to do with the finding,
and a symbol's first commit can predate its bug: `Session.subscribe/1` is
`6cb4e99` by `git log -S`, `git log -L` credits the whole clause to `686acd6`,
and the caller-registration that IS finding N95 arrived with `c3dfda5` — three
commands, three answers, each right for its own question. Blame's answer is the
one anyone can reproduce, so it is the field.

**When the line is wrong because of what an earlier commit did to it, say so in
the sentence** — "what made it wrong" is a fourth thing and it is prose, not a
field. An `Eingeführt` is a claim about age, and age is what decides "now or
never"; a finding whose age is invisible reads as if it were filed today.

`Eingeführt` is the triager's job, not the reviewer's: it needs the tree open.
The reviewer writes `Stand` and `Ort` and is done.

Once closed, only the commit matters — a fix's own hash is the record, so do not
fuss over the fields of a finding that is already in the table.

## Closing a finding

1. **Work it off** against the current branch.
2. **Note the fix in the commit message** (the commit is the durable record; the
   table is only an index).
3. **Move it to the commit table** in `review.md` — one row, `N…` → commit.
   **Write the row only once the commit exists.** A hash noted before the commit
   is a guess, and a guess has been wrong here: the retired `.triaged` record
   named `c6b7d2f`, which never existed. Until the hash exists, anchor the work
   to the `TODO.md` entry or the commit message, never to a guessed hash.
4. **Do not `rm` an open finding.** Closing one is a deletion, and deletions are
   the owner's call — same as any other file.

## Evidence must be reproducible, not narrated

A finding is a claim, and a claim needs a check the next person can run. The
record should carry the **command and its output**, not a retelling of it:
"measured 65 objects reachable only through checkpoint refs" is worth little
next to the `comm -13 … | wc -l` line that produces the 65. Same for a flake —
record the fail rate, the seeds and the tree, or the claim decays into
"it seemed flaky once" (harness feedback, 2026-10-01: the only durable trace of
a repeated suite run was prose). This is also why a finding MUST NOT anchor to
a line number: the **command** is the evidence, the line number is void after
the next rebase.
- **Never `rm` an open finding.** If in doubt, ask the owner.
- **`review.md` stays in the review worktree.** A copy in the main worktree is a
  second unversioned file that drifts; read and write it where it is.

## Why this exists (the evidence)

The previous record, `review-devel-2026-09-30c.md`, was destroyed — not moved —
by the triage agent:

```
10-01 08:36:27Z  read   review-devel-2026-09-30c.md   (25 436 B, 437 lines)
10-01 11:20:41Z  a checkpoint still holds that 25 436 B blob, so the 437-line
                 version was on disk at 11:20
                 (the agent had appended Part 6 in between: final 687 lines / 40 858 B)
10-01 11:33:13Z  rm -f  review-devel-2026-09-30c.md   &&  git commit TODO.md
                 "docs: record the review-devel-2026-09-30c triage (N41-N52)"
```

The `TODO.md` entry covers N41–N52. The findings added in Part 6 — N53–N56 — were
never triaged anywhere, and now survive in no branch, no ref and no blob. The
only reason the 437-line version still exists at all is a checkpoint ref, i.e.
the very bug those lost findings describe.

Earlier the same thing happened to `review.md`, except that one was recoverable:
`review.md` was **tracked** and committed in `ca6f734` before
`9374275 docs: retire the review records now that their findings are triaged`
deleted the working copy. Two differences from today: it was deleted *on purpose,
after the content was in history*, and the findings had first been moved into
`TODO.md`. Both parts are the convention this file now spells out.

The four lost findings were written up in the old
`review-checkpoints-adr036.md.triaged` (N53–N57); all five, plus the process
failure itself, were fixed at `857190e`. That record is now folded into
`review.md`'s closed table — its content is in `857190e`, and keeping the file
beside the single open list was the duplication this consolidation removed.
