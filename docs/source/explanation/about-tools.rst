About the tool subsystem
========================

The tool subsystem lets the agent act on the world: list directories,
read files, later write and execute. This page explains the design and
its policy boundary; the req_llm integration specifics are in
:doc:`about-req-llm`.

Structure
---------

A *tool* is a ``ReqLLM.Tool`` struct — plain data with a name,
description, parameter schema and callback. The registry
(:mod:`CodingAgent.Core.Tools`) owns construction and answers the policy
question "which tools does this session have?". The session loop:
executes requested tools, appends results to the context, and re-calls
the model until a final answer or a loop limit.

Read-only allow-by-policy (slice 2a)
------------------------------------

All tools registered today are read-only by construction, so they run
without a permission check: **allow-by-policy**. The guarantee lives in
exactly one place — the registry's ``read_only/1`` — which is therefore
the single audit point: a tool that writes must never appear there, and
must not bypass the permission gate introduced in slice 2b.

Two defenses bound even the read-only tools:

- **Scope**: every tool receives a scope root (the session's working
  directory); all paths are resolved against it.
- **Physical path resolution**: the scope check runs on the *resolved*
  path, not the textual one. ``..`` segments are normalized first, then
  every path component is walked from the filesystem root, following
  symlinks — including symlinked **directories** inside the path. A
  link (or link-dir) pointing outside the scope is rejected the same as
  an explicit ``../`` escape.

  Why the walk matters: ``Path.expand`` is *textual* — it normalizes
  ``..`` but never follows links. Both escape shapes were verified
  exploitable before the fix
  (``scope/docs/innocent.txt → /etc/shadow`` and
  ``scope/docs/outside-dir → /etc``, then ``outside-dir/passwd``): both
  now return a scope error. Symlinks *inside* the scope (even chains)
  keep working; hard links are deliberately out of scope — they cannot
  be distinguished from a regular file by the filesystem interface and
  a VCS-driven workspace cannot create them.

- **Read caps** (256 KiB) and a global tool-round limit (12 per turn)
  bound context growth and runaway loops — both exist because tool
  output, not the user, is what fills a working context fastest.

The gate (slice 2b)
-------------------

State-changing tools run behind the permission gate: a data table of
``(tool, path-pattern) → :allow | :ask | :deny`` checked before
execution, with human-in-the-loop pause on ``:ask`` (design: ADR 010;
the registry's ``gated/1`` lists them, and the gate inserts at the
loop checkpoint where slice 2a executed unconditionally).

**Class defaults, 2026-09-15** — ``edit`` joined the allow class
(alongside the read-only tools) via the ADR 010 amendment: a gate test
proved allow-by-default for contained edit paths, with ``shell``
still asking on every call. The safety argument (below, "Editing")
is structural: fail-closed matching, physical containment, VCS
reviewability. ``write_file`` and ``webfetch`` remain :ask — a
whole-file overwrite has no uniqueness gate to fail closed, and a
fetch pulls foreign content in. A repo or user layer can still turn
``edit`` back into ask/deny per path (``[permissions.edit] "src/**"
= "ask"``); the class default is only what applies when nothing
matches.

Searching: grep and glob (slice 2d)
-----------------------------------

``grep`` and ``glob`` are read-only and **allow-by-policy** (in the
permission layer's allow class beside ``list_dir``/``read_file``) —
searches never pause at the gate. They are the context-economy tools: is-grep-enough-style
evidence says text search wins on trivial lookups and dies on deep
traces — these tools are the cheap baseline tier; the structural tier
(outlines, call graphs) stays on the roadmap's "Later" list.

Both are read-only and inherit the full containment machinery:
every file and directory that enters a walk must pass
``Tools.in_scope?/2`` — *dirs included*, because a symlinked
directory is a walkable path out of the scope (a lesson the guard
suite enforced twice: first in glob, then again in grep's walk, which
initially descended through an out-of-scope dir link and looped until
the symlink-hop cap tripped).

Pure-string glob matching is compiled to a regex: ``**`` = zero or
more complete segments (``lib/**/*.ex`` reaches ``lib/a.ex`` *and*
``lib/x/y/a.ex``), ``*``/``?`` stay per-segment, ``{a,b}`` braces
expand. Elixir 1.20 removed ``Path.match/2``, so the matcher lives in
:mod:`CodingAgent.Core.Tools.Glob` — plain functions, unit-tested
against the classic glob table.

Caps bound the blast radius: 200 grep matches (capped message tells
the model to narrow the pattern), 500 glob results, 2000 files per
walk, 1 MiB per file, 500-char lines. Binary files are skipped by a
NUL-byte sniff; hidden dirs, ``_build``, ``deps`` and ``.git`` are
never walked (never useful, always wasteful).

Editing: targeted replacement (slice 2e)
-----------------------------------------

``edit`` replaces an exact string: ``old_string`` must occur *exactly
once*, else the tool refuses — a stale match ("not found") and an
ambiguous match ("2 matches — include more surrounding text") are both
errors the model resolves by re-reading and widening. This fail-closed
posture is why it is safe to approve quickly: the tool cannot guess.

That same posture is why **edit is allow-by-policy** (2026-09-15):
contained paths (physically resolved), fail-closed matching (it
declines to act rather than guess), and VCS reviewability (every
landed change is a diff). Approval-per-edit was prompt noise, not
safety — the diff the user reviews in git is the same evidence the
prompt asked them to eyeball, seen earlier and in context. The fence
is structural, like the read-only tools; shell below is the contrast
case.

The empty ``old_string`` create-path (write a new file) is the one
sanctioned creation; on an existing file the same call refuses.

Shell execution (slice 2c)
--------------------------

``shell`` is the one tool with **no path containment** — by design.
A shell trivially bypasses any file-tool check (``cat /etc/passwd``
never touches ``in_scope?``), which is precisely *why* it is gated on
*every* call: v1 has no allow-list for commands, only :ask. The safety
argument changes shape here: file tools are fenced *structurally*
(the check decides), the shell is fenced *socially* (the human
decides, every time).

The timeout is a three-layer contract, because suites differ — a
``mix test`` takes seconds, a Java integration suite takes minutes:

- **model-supplied** ``timeout_secs`` per call (default 300 s) — the
  model knows the job, we don't;
- **soft cap** at the default: higher values are shown prominently at
  the approval prompt so the user can edit them (via the gate's
  ``:edit`` decision) — once shell allow-rules arrive, exceeding the
  soft cap will force :ask even for allow-listed commands;
- **hard cap** at 1800 s: the tool refuses and tells the model to
  split the work. Kill on expiry returns the output captured so far
  plus a timeout note — diagnosis half done.

The real long-term answer for very long jobs is asynchronous runs
(job id, poll/notify) — deferred until session/TUI machinery exists
(roadmap phase 3–4, "Later").

Output is stdout+stderr merged through ``/bin/sh``, capped at 256 KiB
with head+tail kept (tail matters: test summaries live at the end),
and reported with the exit code and wall time — the format is aimed
at the *model's* next decision, not at humans.