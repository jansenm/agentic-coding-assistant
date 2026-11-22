<!--
SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>

SPDX-License-Identifier: MPL-2.0
-->

# Review process — how a finding becomes an issue and gets closed

**Status: provisional.** There is no real review process yet. This repository is
dogfooding its own agent, so "the agent reviews the commits" and "we run the
product" are currently the same activity, and this file only records the
convention that grew out of that — enough to stop losing work. When there is a
real process, this file is replaced by it.

## Consolidated 2026-11-22: findings are GitHub issues

A record per run meant that "what is still open" was a search across six files,
with closed records as `.triaged` archives beside them even though the commits
are the record. That was consolidated into one file, `review.md`, and the file
was then invisible to everyone who was not sitting in front of that worktree: not
linkable from a commit, not readable by a collaborator, not visible to the next
harness that starts in a fresh checkout.

Open findings now live in the **issue tracker** of
`jansenm/agentic-coding-assistant`. The 75 entries that were open in `review.md`
on 2026-11-22 were imported one-to-one; the file is retired.

Rules that survive:

* A finding has a **number**, and the number is the prefix of the issue title:
  `N125: a rename gives one session id two processes`. `N…` is a review finding,
  `P…` a harness-feedback point, `I…` a proposal. Ascending, **never reused**.
* An issue names a **place** (a symbol, never a line number) and, for a defect,
  the **commit that introduced** it. The body headings `## Where` and
  `## Introduced` are those fields; a `Measured at` line names the revision.
* **Closing the issue is the closure.** The fix commit names it (`Fixes #5`) and
  GitHub closes it. There is no table to maintain: the closed issue keeps the
  mapping, and `git log --grep 'N125'` still resolves the number.
* **Do not start a new `review.md`.** If the tracker is unreachable, say the
  finding in the answer and let the owner file it. A second list that drifts is
  what this convention exists to prevent.
* **A number with no issue is a closed finding.** Its record is the commit that
  fixed it (`git log --grep 'N73'`); do not renumber it, and do not re-file it
  without the reason. A reference to an *open* finding is a link (`#56`), never a
  bare number.

## Labels and types

Every issue gets one **type** (a native GitHub field, not a label):

| Type | For |
|------|-----|
| **Bug** | the product behaves differently from what it says |
| **Feature** | an idea or a capability that does not exist yet |
| **Task** | docs, investigations, measurements, a decision to take |

Labels:

* `severity:medium` / `severity:low` — how bad it is when it happens. Imported
  findings carry the severity the review gave them. Ideas carry none.
* `area:session`, `area:tools`, `area:tui`, `area:providers`, `area:prompt`,
  `area:sandbox`, `area:docs`, `area:tests`, `area:harness` — the subsystem.
* `question` — needs a decision before code (`P31` is the model).
* `good first issue` — true for comment and docs corrections; keep it honest.
* `from-review` — temporary import marker; removed once the import is verified.

Priority is **not** a label. "When" is the milestone (`next`, later `v0.1`);
"unmilestoned" means "not scheduled", which is the honest default.

## Roles

| Role             | Who                                    | Does                                    |
|------------------|----------------------------------------|-----------------------------------------|
| **Review agent** | the agent that reviews a commit range  | opens issues with `gh issue create`     |
| **Triage agent** | the agent that works the findings off  | fixes, commits, closes with `Fixes #n`  |
| **Owner**        | the human                              | scope, merges, deletions                |

The review worktree is `agentic-coding-assistant-mjansen`, the main worktree is
`agentic-coding-assistant`. The triage agent works the issues off and commits;
the review agent never does.

**Work in the worktree your context names, and nowhere else.** The two are
linked worktrees of ONE history, on the same filesystem: they do not see each
other's edits, and another harness is usually live in the other one. A `cd` into
the sibling checkout (or an absolute path into it) writes into a second writer's
tree.

**"The owner commits" is a rule about committing, not about writing.** An agent
in build mode EDITS docs, code and issues like any other artefact; the owner
reviews and commits them afterwards. Only the commit (and the merge) is the
owner's.

(Why this sentence exists: a build agent answered one of those tasks with a
proposal instead of an edit — the mode in force was read-only, and the agent
explained the restriction to itself out of the "owner commits" line. If the
mode is ambiguous, WRITE and let the policy refuse: a refused write costs one
turn, a plan the owner did not ask for costs the delivery. See P23, issue #12.)

## The issue body

For a **defect**:

```markdown
Imported from the review record (`N125`, medium).   # only for imported ones

## What happens
the symptom, with the measurement that shows it

## Where
`Session.set_id/2`, `Store.do_rename/2`

## Introduced
`8a34f7b` (2026-09-13)                      # git blame of the offending line

## How we know it is fixed
the observation that would fail today
```

For an **idea**: `## Goal`, `## Why`, `## First step`. An idea has no severity
and no `Introduced`; it has a target and a first step.

Keep the **command and its output** in the body. "Measured 65 objects" is worth
little next to the `comm -13 … | wc -l` line that produces the 65.

## Relationships, not prose

A real dependency is a GitHub **relationship**, not a sentence: `blocked by` /
`blocking`, set through the API (`addBlockedBy`). It shows on both issues, it
survives edits to either body, and it cannot point at a number that has no issue
— the failure this record had to fix by hand once (I15 depended on I6, which had
been closed and therefore had no issue to link to).

```sh
gh api graphql -H 'GraphQL-Features: issue_dependencies' \
  -f query='mutation { addBlockedBy(input: {issueId: "I_…", blockingIssueId: "I_…"}) { issue { number } } }'
```

Prose still links the softer relation ("see also", "same class as", `#56`), but
never carries a blocker on its own.

**Sub-issues** are for work that belongs *inside* one issue — a checklist with
its own state — not for a dependency between peers.

## Three fields, three jobs

`Measured at`, `Where` and `Introduced` are not synonyms, and treating them as
one is how a whole review round came to anchor on a docs commit from the day the
review was written instead of the months-old line that carries the bug. Three
questions, three commands:

| Field | Question | Who fills it | Command |
|-------|----------|--------------|---------|
| **Measured at** | which revision did I read? | the reviewer, once per issue | `git rev-parse --short HEAD` + branch + date, and say "dirty" if the tree was not clean |
| **Where** | where do I find it now? | the reviewer | the module + symbol (function, attribute, prompt section) |
| **Introduced** | how old is the bug? | whoever works it off | `git blame -L <line>,<line> --date=short -- <path>` |

**Blame the offending line — not the file, not the symbol.** `git log -1 --
<path>` almost always names a commit that had nothing to do with the finding,
and a symbol's first commit can predate its bug: `Session.subscribe/1` is
`6cb4e99` by `git log -S`, `git log -L` credits the whole clause to `686acd6`,
and the caller-registration that IS finding N95 arrived with `c3dfda5` — three
commands, three answers, each right for its own question. Blame's answer is the
one anyone can reproduce, so it is the field.

**When the line is wrong because of what an earlier commit did to it, say so in
the sentence** — "what made it wrong" is a fourth thing and it is prose, not a
field. An `Introduced` is a claim about age, and age is what decides "now or
never".

`Introduced` is the triager's job, not the reviewer's: it needs the tree open.
The reviewer writes `Measured at` and `Where` and is done.

## Closing a finding

1. **Work it off** against the branch the issue names.
2. **The commit says why** — the diff says what, the message says why — and it
   names the issue: `Fixes #5` closes it, `Refs #5` leaves it open for the rest
   of the work.
3. **Do not close what you did not fix.** A "won't do" is the owner's closure,
   with the reason in a comment.
4. **A finding that turns out to be wrong is closed with the disproof** in a
   comment. That is evidence too, and it stops the claim from being re-filed.
5. **Never write a hash that does not exist yet.** Until the commit is made,
   anchor the work to the issue, not to a guessed hash: the retired `.triaged`
   record named `c6b7d2f`, which never existed.

## Committing

* **Match the house style**: `type(scope): subject, and the why when it is not
  obvious`, then a blank line, then the body. `git log --oneline -20` shows it;
  read it before writing.
* **A body is not optional for a finding fix.** It carries the diagnosis, the
  measurement and the rejected alternative. If the message needs the issue
  number, it needs the body too.
* **The agent's `git` tool takes it as one argument with embedded newlines**:
  `args: ["commit", "-m", "subject\n\nbody"]`. No temp file, no `-F`, no second
  round trip.

## Evidence must be reproducible, not narrated

A finding is a claim, and a claim needs a check the next person can run. The
issue carries the **command and its output**, not a retelling of it. Same for a
flake — record the fail rate, the seeds and the tree, or the claim decays into
"it seemed flaky once" (harness feedback, 2026-10-01: the only durable trace of a
repeated suite run was prose). This is also why a finding MUST NOT anchor to a
line number: the **command** is the evidence, the line number is void after the
next rebase.

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

The `TODO.md` entry covers N41–N52. The findings added in Part 6 — N53–N56 —
were never triaged anywhere, and survive in no branch, no ref and no blob. The
only reason the 437-line version exists at all is a checkpoint ref, i.e. the very
bug those lost findings describe.

That is the argument for the tracker: an issue cannot be deleted by a `rm` in
someone's worktree, and it carries the evidence the findings above had to be
reconstructed from.
