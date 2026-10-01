# Review process — how a review record is handed over and triaged

**Status: provisional.** There is no real review process yet. This repository is
dogfooding its own agent, so "the agent reviews the commits" and "we run the
product" are currently the same activity, and this file only records the
convention that grew out of that — enough to stop losing work. When there is a
real process, this file is replaced by it.

## Roles

| Role | Who | Writes to |
|---|---|---|
| **Review agent** | the agent that reviews a commit range | the record, in the review worktree |
| **Triage agent** | the agent that works the findings off | `TODO.md` in the main worktree |
| **Owner** | the human | decides scope; commits |

The review worktree is `agentic-coding-assistant-mjansen`, the main worktree is
`agentic-coding-assistant`. The triage agent reads the record across worktrees,
and it commits — the review agent never does.

## The record

- Name: `review-<subject>.md`, in the review worktree, **untracked** (the owner
  commits code changes, not review artefacts).
- Findings are numbered `N1, N2, …`, ascending, **never reused**. A range that is
  reviewed twice keeps counting up; it does not restart.
- Anchor every finding to a **symbol plus the commit that introduced it** — never
  to a line number, which is void after the next rebase.
- The record is a handover artefact, not scratch space. Deleting it destroys the
  only durable copy of the findings.

## Handover: rename, do not delete

When the triage agent has worked a record off:

1. **Read** the record. If the file is not what it expects (grown since the read,
   partial, unreadable), say so instead of proceeding.
2. **Triage**: work the findings off against the current branch.
3. **Record the triage in `TODO.md`** — an entry naming the record file and the
   finding numbers, with the commit that addressed each.
4. **Append a closing line to the record** before renaming it: a short
   `## Closed by` section naming the commit(s) that addressed each finding, so
   the record stands on its own. Without it a `.triaged` record can still say
   "…are still open" (observed: `review-checkpoints-adr036.md` ended with the
   four lost findings marked open while `857190e` had fixed them — only the
   `TODO.md` entry carried the commit).
5. **Rename the file in place**: `review-<subject>.md` → `review-<subject>.md.triaged`.
   The record stays readable; `ls review*` shows what has been worked off
   (`.md.triaged`) and what has not (`.md`).
6. **Leave it there.** If a record needs to go, that is the owner's decision, not
   a side effect of triaging.

Rules that follow from that:

- **Partial triage keeps the plain name.** If some findings are still open, the
  file stays `review-<subject>.md` and the `TODO.md` entry names the open numbers.
  A `.triaged` suffix means "no finding in this file is still open".

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
- **Never `rm` a record.** If in doubt, ask the owner.
- **Do not move a record out of the review worktree.** A copy in the main
  worktree is a second unversioned file that drifts; read it where it is.

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

The four lost findings are written up in
`review-checkpoints-adr036.md.triaged` (N53–N57); all five, plus the process
failure itself, were fixed at `857190e` and recorded as closed in that file's
`## Closed by` section and in `TODO.md`.
