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

State-changing tools (``write_file``, ``shell``) will not enter the
registry until the permission gate exists: a data table of
``(tool, path-pattern) → :allow | :ask | :deny`` checked before
execution, with human-in-the-loop pause on ``:ask``. The design is
tracked as ADR 010 and the roadmap's slice 2b; the gate inserts at the
checkpoint in the loop where slice 2a currently executes unconditionally.