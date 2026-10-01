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

Review records and how they are handed over are described in
`review-process.md`.