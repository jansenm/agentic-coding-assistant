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

Review findings and harness feedback both live in **`review.md`** — the one
list of what is open (see `review-process.md` for the convention). Say it in
your answer, and add a numbered entry there (or the owner will, if it came
up in conversation).