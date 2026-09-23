About the tool subsystem
========================

The tool subsystem lets the agent act on the world: list and read files,
search them, edit and write them, and run commands. This page explains the
design and its policy boundary; the req_llm integration specifics are in
:doc:`about-req-llm`.

Structure
---------

A *tool* is a ``ReqLLM.Tool`` struct — plain data with a name,
description, parameter schema and callback. The registry
(:mod:`CodingAgent.Core.Tools`) owns construction and answers the policy
question "which tools does this session have?" — ``read_only/1`` for the
tools that run without a check, ``gated/1`` for the ones that answer to
the permission gate. The session loop: executes requested tools, appends
results to the context, and re-calls the model until a final answer or a
loop limit.

Read-only allow-by-policy (slice 2a)
------------------------------------

The original seven tools are read-only by construction, so they run
without a permission check: **allow-by-policy**. The guarantee lives in
exactly one place — the registry's ``read_only/1`` — which is therefore
the single audit point: a tool that writes must never appear there, and
must not bypass the permission gate introduced in slice 2b.

Two defenses apply even to the read-only tools:

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

- **Read caps** (256 KiB per file, 1 MiB per grepped file, 200 grep
  matches, 500 glob results, 2000 files per walk) and a **per-turn
  tool-round budget** bound context growth and runaway loops — both exist
  because tool output, not the user, is what fills a working context
  fastest. The budget is layered (``max_tool_rounds`` in ``config.toml``,
  project over global; default 100) and, when it trips interactively, it
  asks the user whether to continue with another budget or wrap the turn
  up (ADR 025).

The gate (slice 2b)
-------------------

State-changing tools run behind the permission gate: a data table of
``(tool, path-pattern) → :allow | :ask | :deny`` checked before
execution, with human-in-the-loop pause on ``:ask`` (design: ADR 010;
the registry's ``gated/1`` lists them, and the gate inserts at the
loop checkpoint where slice 2a executed unconditionally).

**Class defaults, 2026-09-15** — ``edit`` and ``write_file`` joined
the allow class (alongside the read-only tools) via the ADR 010
amendment: gate tests proved allow-by-default for contained paths,
with ``shell`` still asking on every call. The safety argument is
structural: physical containment plus VCS reviewability (every
landed change is a git diff). ``webfetch`` remains :ask — a fetch
pulls foreign content in. A repo or user layer can still turn
``edit``/``write_file`` back into ask/deny per path
(``[permissions.edit] "src/**" = "ask"``); the class default is only
what applies when nothing matches.

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

Delegation: two engines, one answer (ADR 016)
---------------------------------------------

Both tools delegate to the native engine when it is on ``PATH``
(``rg`` for grep, ``fd`` for glob) and keep the Elixir walk as the
reference fallback (portability, and a machine with no ``rg``/``fd``
and no network to install one). The delegated run goes through
``Exec`` under the read-only sandbox profile — the same single
execution path as ``shell`` and ``git``.

The reference engine **defines** the answer; the native engine is
measured against it. Measured, the two used to be two tools wearing
one name: ``fd --glob`` matches the entry *name*, so every documented
shape with a ``/`` (``lib/**/*.ex``) returned 0 files where the walk
found 59; both binaries are smart-case by default; ``fd``'s dialect is
richer (character classes, ``!`` negation, ``\`` quotes); ``rg``'s own
glob was *narrower* than ours and silently dropped matches; a
non-zero exit was formatted as a result (``Exec`` merges stderr into
stdout). So:

- a pattern with a ``/`` goes to ``fd`` root-anchored and absolute
  (``--absolute-path --full-path``), and a pattern fd would read
  differently stays on the reference engine (``fd_dialect?/1``);
- ``rg`` never receives the caller's glob: it searches wide and every
  match is re-filtered by ``Glob.file_match?/3`` — the one rule, in
  one function, so a pattern means the same thing in ``glob`` and in
  ``grep``'s ``glob`` argument;
- errors are not results: a non-zero exit falls back to the walk
  (``fd`` reports "no matches" with exit 0 — the 0/1 convention
  belongs to its ``--quiet`` flag).

``SearchDelegationTest`` "engine agreement" pins it: every documented
shape runs twice, once with the binary and once with the probe forced
off, and the two answers must be identical.

Hidden entries: a default, not a wall
-------------------------------------

Hidden entries are skipped in both engines by the *same* rule
(``Containment.hidden_entry?/1`` — any dot segment, files and
directories alike; before it the walk pruned hidden *dirs* only, so a
plain search saw dotfiles that ``rg``/``fd`` never returned), and the
way to ask for them is to **name** them (``.gitignore``, ``.*``,
``.idea/*``, ``path: ".github"``) — POSIX spelling, nothing new to
remember. ``--hidden`` is passed to both binaries so a named entry can
be found, and the result is filtered afterwards so a pattern that did
not ask cannot gain one.

The build/vendor list is separate and always applies: ``_build``,
``deps``, ``.git``, ``doc``, ``cover``, ``.elixir_ls`` are never
walked (never useful, always wasteful) — except when named as the
target, because naming beats filtering at every layer.

Binary files are skipped by a NUL-byte sniff and long lines are clipped at
500 chars, so a minified file cannot blow up the context.

Editing: targeted replacement (slice 2e)
----------------------------------------

``edit`` replaces an exact string: ``old_string`` must occur *exactly
once*, else the tool refuses — a stale match ("not found") and an
ambiguous match ("2 matches — include more surrounding text") are both
errors the model resolves by re-reading and widening. This fail-closed
posture is why it is safe to approve quickly: the tool cannot guess.

That same posture is why **edit and write_file are allow-by-policy**
(2026-09-15): contained paths (physically resolved) and VCS
reviewability (every landed change is a diff; `write_file` additionally
fails closed on the match, so it cannot guess or spray). Approval
per call was prompt noise, not safety — the diff the user reviews in
git is the same evidence the prompt asked them to eyeball, seen
earlier and in context. The fence is structural, like the read-only
tools; shell below is the contrast case.

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