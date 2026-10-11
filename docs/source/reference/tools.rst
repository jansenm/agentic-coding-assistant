Tools reference
===============

The tools a session carries are defined once, in
``CodingAgent.Core.Tools`` — this page is the human view of the same
registry. Tools fall into three buckets: **read-only** (always available,
including to a read-only agent), **gated** (state-changing; run behind the
permission gate, ADR 010), and **delegation** (the ``task`` tool, primary
agents only, ADR 017/018).

The scope
---------

Every path tool is bounded to the session's **scope root** (the working
directory, ADR 030): reads outside it are rejected and the sandbox mounts
the rest of the filesystem read-only. ``grep``/``glob`` are front ends to
a **required** engine — ``rg`` for content, ``fd`` for filenames — so a
missing binary is a named error naming the binary to install, not a silent
fallback (ADR 030).

Read-only tools
---------------

.. list-table::
   :header-rows: 1
   :widths: 18 82

   * - Tool
     - What it does
   * - ``list_dir``
     - List a directory's entries (names, one per line; directories marked
       with a trailing slash).
   * - ``read_file``
     - Read a text file. Files over 256 KiB are rejected; to read a large
       file (or a spilled tool output named in a truncation note), pass
       ``offset`` and ``limit``.
   * - ``grep``
     - Search file contents by regular expression; returns
       ``path:line: text``, skips binaries, bounded result count. Large
       output spills to a readable file (ADR 038).
   * - ``glob``
     - Find files by glob pattern (``lib/**/*.ex``); hidden and
       build/vendor directories are skipped.
   * - ``question``
     - Ask the human a question and wait for the answer (ADR 027). The
       session intercepts the call; available to every agent.
   * - ``todowrite``
     - Maintain the task list (ADR 031). Pure session state, intercepted,
       never parks. Each item may carry agent-private ``notes`` that
       survive compaction.
   * - ``compact``
     - Summarize older messages now to free context (ADR 040). The model's
       own compaction lever; intercepted by the session.

Gated tools
-----------

These run behind the permission gate. Since ADR 030 every session is
confined, so ``shell``/``git`` are allowed by default; a stated escalation
(for example ``network`` on ``shell``) asks first.

.. list-table::
   :header-rows: 1
   :widths: 18 82

   * - Tool
     - What it does
   * - ``write_file``
     - Create or overwrite a file. The parent directory must exist; pass
       ``parents: true`` to create it (a confined ``mkdir --parents``).
       Auto-approved unless a permissions file tightens it.
   * - ``edit``
     - Replace an exact string in a file; the match must be unique.
   * - ``delete_file``
     - Delete a path (a confined ``rm``). A plain file needs no flag;
       ``dir`` removes an empty directory (or a symlink — the link, not
       its target), ``recursive`` a directory with its contents.
   * - ``move_file``
     - Move or rename a path (a confined ``mv``). ``to`` is the exact new
       path (``-T``); an existing destination is refused unless
       ``force`` is set; a symlink moves as a link.
   * - ``shell``
     - Run a command through ``/bin/sh`` in the scope root; captures
       stdout+stderr and the exit code. Default timeout 300 s, hard cap
       1800 s.
   * - ``git``
     - Run a git subcommand (arguments as a list); may write ``.git``
       (commit/tag/reset) through its own sandbox profile.
   * - ``webfetch``
     - Fetch a public http(s) page, HTML stripped to text, body capped;
       local/private addresses are refused.

Delegation
----------

.. list-table::
   :header-rows: 1
   :widths: 18 82

   * - Tool
     - What it does
   * - ``task``
     - Delegate a self-contained, read-heavy job to a subagent and get
       back only its final summary (ADR 017/018). Available to primary
       agents only; a subagent is depth 1 and cannot delegate further. The
       subagents offered are the ``mode: subagent``/``all`` agent
       definitions (ADR 042's ``explore`` ships).
