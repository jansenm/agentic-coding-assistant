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

The read-only tools — ``list_dir``, ``read_file``, ``grep``, ``glob``
and ``todowrite``, plus ``question`` (answered by the session, not
executed) — are read-only by construction, so they run without a
permission check:
**allow-by-policy**. The guarantee lives in exactly one place — the
registry's ``read_only/1`` — which is therefore the single audit point: a
tool that writes must never appear there, and must not bypass the
permission gate introduced in slice 2b.

Since **ADR 030 the sandbox profile is the one boundary**: the native
file tools run their operation as a *confined child process* (a
``cat``/``tee``/``ls`` under the session's profile), so what they can
reach is exactly what the profile exposes — a ``hide``\ d path reads as
the empty image, read-only binds fail a write, and the scope root's
read-write bind is the only writable tree. Two properties are worth
keeping in mind:

- **Scope**: every tool receives a scope root (the session's working
  directory); relative paths resolve against it, and the process's
  working directory is pinned there.
- **Physical path resolution** is the discovery filter on every
  *enumeration*: a ``grep``/``glob`` engine must not REPORT a path that
  resolves outside the scope through a link (the ``Tools.in_scope?/2``
  re-check). Enforcement is the engine's confinement; this filter only
  keeps an out-of-scope result from being shown.

  Why textual expansion is not enough: ``Path.expand`` normalizes
  ``..`` but never follows links, so an in-scope-looking symlink can
  point out. Both escape shapes were verified exploitable before the
  fix (``scope/docs/innocent.txt → /etc/shadow`` and
  ``scope/docs/outside-dir → /etc``, then ``outside-dir/passwd``): both
  are now filtered. Symlinks *inside* the scope (even chains)
  keep working; hard links are deliberately out of scope — they cannot
  be distinguished from a regular file by the filesystem interface and
  a VCS-driven workspace cannot create them.

- **Read caps** (256 KiB per file, 200 grep
  matches, 500 glob results) and a **per-turn
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

**Class defaults, ADR 030 (2026-09-27)** — ``edit``/``write_file``
joined the allow class in 2026-09-15 (contained, reviewable as a git
diff); ``shell``/``git`` joined with ADR 030, because a session only
exists under a confining sandbox and the profile is their boundary.
A stated escalation (``network``/``git_write``) still asks, and
``webfetch`` remains :ask — a fetch pulls foreign content in. A repo
or user layer can turn any tool back into ask/deny per path
(``[permissions.edit] "src/**" = "ask"``); the class default is only
what applies when nothing matches, and since ADR 030 a session start
REFUSES when no confining sandbox is available.

Searching: grep and glob (slice 2d)
-----------------------------------

``grep`` and ``glob`` are read-only and **allow-by-policy** (in the
permission layer's allow class beside ``list_dir``/``read_file``) —
searches never pause at the gate. They are the context-economy tools: is-grep-enough-style
evidence says text search wins on trivial lookups and dies on deep
traces — these tools are the cheap baseline tier; the structural tier
(outlines, call graphs) stays on the roadmap's "Later" list.

``rg``/``fd`` are **required** since ADR 030: the retired Elixir walk
was a second, unconfined boundary, so a missing binary is a clear error
instead of an unconfined search. Every returned path is still re-checked
with ``Tools.in_scope?/2`` (*dirs included*, physically resolved), so an
engine can never REPORT an out-of-scope path however it traversed.

Pure-string glob matching is compiled to a regex: ``**`` = zero or
more complete segments (``lib/**/*.ex`` reaches ``lib/a.ex`` *and*
``lib/x/y/a.ex``), ``*``/``?`` stay per-segment, ``{a,b}`` braces
expand. Elixir 1.20 removed ``Path.match/2``, so the matcher lives in
:mod:`CodingAgent.Core.Tools.Glob` — plain functions, unit-tested
against the classic glob table.

Delegation: one engine, one answer (ADR 016 / ADR 030)
------------------------------------------------------

Both tools delegate to the native engine (``rg`` for grep, ``fd`` for
glob). Since ADR 030 there is no Elixir fallback: the walk was a second,
unconfined boundary, so the binaries are required and a missing one is a
clear error, not an unconfined search. The delegated run goes through
``Exec`` under the read-only sandbox profile — the same single execution
path as ``shell`` and ``git``.

The delegated engine does not define the answer; a reference rule does,
and the engine's output is measured against it. Measured, ``fd
--glob`` matches the entry *name*, so every documented shape with a
``/`` (``lib/**/*.ex``) returned 0 files where the reference rule found
59; both binaries are smart-case by default; ``fd``'s dialect is
richer (character classes, ``!`` negation, ``\`` quotes). So the engine
only ever **enumerates or pre-filters**, and the filter decides:

- ``fd`` is called wide (``--glob '*'``, bounded by ``--max-results``)
  when the caller's pattern is not a shape fd reads the same way;
  otherwise it is called root-anchored and absolute
  (``--absolute-path --full-path``);
- ``rg`` never receives the caller's glob: it searches wide and every
  match is re-filtered by ``Glob.file_match?/3`` — the one rule, in
  one function, so a pattern means the same thing in ``glob`` and in
  ``grep``'s ``glob`` argument;
- an error is not a result: a non-zero exit is formatted as the error
  it is (``fd`` reports "no matches" with exit 0 — the 0/1 convention
  belongs to its ``--quiet`` flag).

``SearchDelegationTest`` pins the reference rule: every documented shape
is checked against the engine's enumeration and the filter's answer, and
the two must agree.

Hidden entries: a default, not a wall
-------------------------------------

Hidden entries are skipped by the *same* rule in both
(``Containment.hidden_entry?/1`` — any dot segment, files and
directories alike), and the way to ask for them is to **name** them
(``.gitignore``, ``.*``, ``.idea/*``, ``path: ".github"``) — POSIX
spelling, nothing new to remember. ``--hidden`` is passed to both
binaries so a named entry can be found, and the result is filtered
afterwards so a pattern that did not ask cannot gain one.

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

``shell`` has **no path containment** — by design. A shell trivially
bypasses any file-tool check (``cat /etc/passwd`` never touches
``in_scope?``), which is why it always ran behind the gate; ADR 030
made the *profile* its boundary, so inside a confining sandbox it is
allow-by-default (a stated escalation still asks). The fence is now the
namespace, not a command inspection.

The timeout is a three-layer contract, because suites differ — a
``mix test`` takes seconds, a Java integration suite takes minutes:

- **model-supplied** ``timeout_secs`` per call (default 300 s) — the
  model knows the job, we don't;
- **soft cap** at the default: higher values would be shown at a
  (policy-driven) approval prompt so the user can edit them (via the
  gate's ``:edit`` decision);
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