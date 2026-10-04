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
anchored to symbol + commit. Closed findings are deleted from it; a short
table at the foot maps an old `N…`/`P…` to its fixing commit so a cited
number still resolves.

Rules that survive:

* A finding has a **number** (`N…`, ascending, never reused) or a feedback
  point (`P…`).
* Anchor to **symbol + commit**, never a line number.
* **Do not `rm` a finding while it is open.** Closing one — moving it to the
  commit table — is the owner's call (same as any deletion).
* A record that is fully worked off is **deleted**, not renamed: its fixes
  are commits, and `review.md`'s table names them. (The old
  `review-<subject>.md.triaged` convention is retired; it produced two files
  whose own `## Closed by` line named a commit that did not exist — see
  N70.)


## Roles

| Role             | Who                                   | Writes to                          |
|------------------|---------------------------------------|------------------------------------|
| **Review agent** | the agent that reviews a commit range | `review.md`, in the review worktree |
| **Triage agent** | the agent that works the findings off | `review.md` (close) + `TODO.md`    |
| **Owner**        | the human                             | decides scope; commits; deletes    |

The review worktree is `agentic-coding-assistant-mjansen`, the main worktree is
`agentic-coding-assistant`. The triage agent reads `review.md`, works the
findings off, and commits — the review agent never does.

## The record

- **One file: `review.md`**, in the review worktree, **untracked** (the owner
  commits code changes, not review artefacts). One place for everything open.
- Findings are numbered `N1, N2, …`, ascending, **never reused**. A new review
  continues the count; it does not restart.
- Anchor every finding to a **symbol plus the commit that introduced it** — never
  to a line number, which is void after the next rebase.
- **Deleted when closed**, not archived. A short table at the foot of
  `review.md` maps the number to its fixing commit, so a cited `N…` still
  resolves.

## Closing a finding

1. **Work it off** against the current branch.
2. **Move it to the commit table** in `review.md` — one row, `N…` → commit.
3. **Note the fix in the commit message** (the commit is the durable record; the
   table is only an index).
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
a line number: the command is the anchor, the line number is void after the
next rebase.
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
