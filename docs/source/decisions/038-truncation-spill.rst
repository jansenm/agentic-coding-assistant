:orphan:

Truncation spills to the session scratch; read_file reads in windows
====================================================================

.. adr::
   :id: 038
   :status: Accepted
   :date: 2026-09-29
   :tags: tools, context, sessions, sandbox

.. note::
   Accepted 2026-09-29; implemented the same day. Fixes the T14 loss: the
   truncation that protects
   the context model (``Exec.truncate/1``, ``grep``'s cap, ``webfetch``'s
   cap) currently **discards** the overflow for good. The scratch
   directory of ADR 022 already exists and is bound at ``/tmp`` inside
   the sandbox, so the overflow has a natural, confined, session-lifetime
   home. ``read_file`` gains a line window so a spilled file larger than
   its 256 KiB whole-file cap is actually retrievable.

Context
-------

Three places bound what a tool puts in the model's context, and all three
throw the rest away:

- ``Exec.truncate/1`` keeps head + tail past 256 KiB (``shell``, ``git``);
- ``grep`` caps at 200 matches and clips each line to 500 chars;
- ``webfetch`` keeps the first 128 KiB of the de-tagged body.

The bound itself is right — an unbounded tool result would blow the
window and burn quota (the same lesson as ADR 037). What is wrong is the
**loss**: a shell command that prints 2 MB of test output, a ripgrep hit
list of 900 matches, a long page — the model sees the head and tail and
can never look closer. It then re-runs the command (the very rework loop
ADR 037 attacked) or gives up. T14 records this and notes the store for
the lost text already exists: ``Core.Session.Scratch`` (ADR 022), bound
over ``/tmp`` inside the sandbox for the session's lifetime.

A second fact shapes the design: the overflow is, **by definition**,
larger than the cap that triggered the spill — so it is larger than
``read_file``'s 256 KiB whole-file cap. A spill path the model cannot
open is not "retrievable". So this ADR also gives ``read_file`` a line
window (``offset``/``limit``), which is opencode's ``read`` shape and the
missing half of the same feature.

The question this ADR settles
-----------------------------

- **Where does the overflow go?** The session scratch is the one place
  that is (a) writable by us, (b) reachable by the confined file tools
  (``/tmp`` bind), (c) scoped to the session and cleaned with it, and
  (d) already implemented. A host path outside the sandbox would be
  unreadable; a BEAM-side temp file would violate "no scope-relevant
  filesystem access in the BEAM" (it would not — scratch is ours — but it
  would sit outside the one boundary for no gain).
- **How does the model find it?** The truncation note names the exact
  path, in the same vocabulary the model already uses: ``/tmp/…``.
- **How does the model read a file bigger than ``read_file``'s cap?**
  A line window, read as a confined ``sed`` range — not a BEAM read of
  the whole file (which would defeat the cap in memory).

Decision
--------

**1. Truncation spills the overflow into the session scratch and names
the path.** A new ``Core.Spill`` module owns the write and the one naming
rule:

- host file: ``<scratch>/spill/<label>-<unique>`` (``<scratch>`` is
  ``Core.Session.Scratch.path/1``);
- path reported to the model: ``/tmp/spill/<label>-<unique>`` — the
  same file as the sandbox sees it (ADR 022 binds scratch at ``/tmp``);
- ``<label>`` is the tool (``shell``, ``grep``, ``webfetch``), so a
  directory listing is legible.

When a scope carries no session id (a bare test scope), there is no
scratch: ``Spill.spill/3`` returns ``:no_scratch`` and the tool keeps
today's behaviour (head+tail marker, no path). The feature degrades to
"not available", never to "an unreadable path". **Amended by ADR 046:**
``Sandbox.None``, named here in the original, is deleted; "no session id"
is the only no-scratch case.

**2. ``Exec``, ``grep`` and ``webfetch`` spill.** ``Exec.run/5`` already
receives the profile (which carries ``:scratch``); a new ``:label``
option names the spill, and ``finish/3`` writes the FULL buffer to
scratch when it would truncate, replacing the head/tail marker with a
note that names the path and gives the head. ``grep`` spills the full
match list; ``webfetch`` spills the full de-tagged text. All three share
``Core.Spill`` — one writer, one naming rule.

.. note::
   A review caught that "full match list" was originally untrue: ``grep``
   ran ``rg`` through ``Exec`` with the default truncation, so it received
   only a 256 KiB fragment of the stream, and both the reported match count
   and the spill were drawn from that fragment (measured: "1133 of 1133"
   for 120 000 hits). ``grep`` now reads the stream whole
   (``Exec.run(…, truncate: false)``), so the count and the spill are
   both complete; the timeout bounds the search and ``Core.Spill`` caps
   the file.

   Reading the stream whole exposed two costs, both fixed. First, the
   stream was ``rg --json`` — ~6x larger than the plain output for a
   normal search and ~25x for a broad one (measured: pattern ``.`` over
   500 files produced 16 MB of JSON), all of it decoded line by line;
   ``grep`` now uses ``rg --null`` (``path\0line:text``), which carries
   the same matches at a fraction of the size with a cheap split. Second,
   the per-match physical scope re-check is a full realpath walk; run per
   match it was quadratic in hits (20k matches → 4.4 s). It now resolves
   once per DISTINCT file (20k matches over 500 files → 69 ms), so the
   symlink-escape guard (an explicitly named link can read out of scope)
   still holds.

**3. ``read_file`` gains ``offset`` and ``limit`` (1-based lines).** Read
as a confined ``sed -n 'start[,end]p'`` through ``Tools.FileExec``, so the
read is bounded in the child, not in BEAM memory. Behaviour:

- no ``offset``/``limit``: unchanged — whole file, rejected past 256 KiB;
- with a window: the requested lines only, of **any** size file, with a
  trailing note giving the total line count (one confined ``wc -l``) so
  the model can page. The 256 KiB whole-file cap does not apply to a
  window: the window itself is bounded by ``limit``.

**4. A spill is bounded too.** The scratch has no quota (ADR 022 open
question), so a single spill is capped (default 16 MiB): past that the
note says the overflow was truncated as well. This keeps one pathological
command from filling ``/tmp`` — the same head+tail discipline, applied to
the spill file, and recorded honestly.

Mechanism
---------

- ``Core.Spill`` (new): ``spill(content, scope, label) :: {:ok, path} |
  :no_scratch | {:error, reason}``; ``dir/1`` (the host spill dir),
  ``sandbox_path/1`` (host → the ``/tmp/…`` the model sees), the size cap
  and the naming rule. ``Scratch.from_scope/1`` is reused — no second
  scope rule.
- ``Exec``: ``run/5`` learns ``:label`` (default ``"exec"``). The head
  + tail cut named in the Context above as ``Exec.truncate/1`` now lives
  in the output accumulator (``Exec`` local ``finish/2``, fed by
  ``ingest/2``) after the amendment below made it streaming; the public
  ``Exec.truncate/1`` no longer exists. The accumulator STREAMS into the
  spill once it passes the cap, so the spill is written while the command
  runs, not assembled as one big binary first. ``Exec.format`` is
  unchanged (it renders whatever ``run`` returned).
- ``grep``: ``format_results/1`` takes the scope; on the cap path it
  spills the full set and appends the path note.
- ``webfetch``: ``tool/1`` passes the scope; ``cap/2`` spills the full
  text before de-tagging loss.
- ``read_file``/``FileExec``: an optional window; ``FileExec.read_window/6``
  runs ``sed`` and (for the total) ``wc``. ``read_file`` validates
  ``offset``/``limit`` as positive integers.

Consequences
------------

- The model can retrieve what was truncated: re-run pressure drops, which
  is the point (ADR 037's rework loop, one layer down).
- The scratch's purpose grows from "workspace between shell calls" to
  "workspace + tool-output store"; it is already session-scoped and
  cleaned by the lifecycle verbs, so the store inherits that lifetime and
  is gone after a reboot — correct ``/tmp`` semantics, and a spilled path
  in an old session's context is expected to be gone.
- ``read_file`` reaches parity with opencode's ``read`` for large files
  (offset/limit), independent of spilling.
- Cost: three call sites learn about ``Core.Spill``; the spill writes are
  disk I/O in the tool process (bounded by the 16 MiB cap). Tests need a
  scratch-bearing scope to exercise the spill path, and the mapping
  host-path → ``/tmp``-path must be asserted once.

Open questions
--------------

1. **Quota / cleanup cadence.** ADR 022 defers a directory quota. The
   16 MiB per-spill cap bounds one file, not the directory; many spills
   in one long session can still grow scratch. A session-level sweep (on
   session end, or "keep the newest N spills") is deferred; the lifetime
   already ends with the session.
2. **Spill of ``read_file``'s own cap.** ``read_file`` rejects a >256 KiB
   file rather than spilling it (the model can ask for a window instead).
   Should a rejected whole read offer to spill a preview? Deferred — the
   window is the answer.
3. **Compaction's ``@render_result_chars`` cap.** ``Compaction.render/1``
   truncates a tool result for the summarizer (not for the model); that
   is a lossy-summary concern (ADR 037), not a retrieve-the-full-text
   concern. Out of scope.

Amendment 2026-09-30: the spill is written as the command runs
--------------------------------------------------------------

**Status: Accepted; shipped the same day.**

The mechanism above bounded what the MODEL sees, but not what the BEAM
HELD while the command ran: ``Exec.collect/5`` appended every chunk to a
buffer and truncated only when the process exited. A fast, unbounded
printer (``while true; do echo; done``, ``yes``, a runaway ``find``) grew
the BEAM to **11 GB**; four OOM kills in 26 minutes froze the whole
desktop (RAM+swap exhausted, ``journald`` watchdog starved for 3 min).
The same class hit ``grep``/``glob``, whose ``truncate: false`` contract
keeps the whole stream by design, and ``read_file``, where the 256 KiB
cap was checked only AFTER a full ``cat``.

The accumulator now STREAMS. It buffers up to ``@max_bytes`` (256 KiB);
crossing that materializes once, freezes the head, starts a rolling tail
window (``@tail_bytes``), and appends every further chunk to the spill
file via ``Spill.open_writer/2``/``write/2``/``finish/1``. Memory is
O(``@max_bytes``) regardless of output size, and the spill — the same
``/tmp/spill/<label>-<n>`` file the model is told to read — is written
incrementally, bounded by the existing 16 MiB per-spill cap. The writer
keeps the SAME head+tail shape as ``spill/3`` (review N35: the first
writer dropped the tail, so the two paths disagreed): the head streams
to the file, the marker is written at the cap, and the last
``@tail_bytes`` is held and flushed by ``finish/1`` — the tail is the
useful part of a crashed build's log.

Two consequences:

- ``truncate: false`` (``grep``/``glob``) cannot use a head/tail cut, so
  it keeps the whole stream but now under a hard ``@max_raw_bytes``
  (64 MiB) safety cap: past it the command is killed and the caller gets
  a bounded ``:raw_too_large`` failure (``rg``/``fd`` surface it as their
  own error), not an OOM. It carries only the SIZE, never the buffer
  (review N38: materializing the 64 MiB buffer in the failure path was
  the O(cap) the cap exists to avoid).
- ``read_file``'s over-cap rejection is unchanged in message, but the
  BEAM no longer holds the whole oversized file first: the buffer is
  capped at 256 KiB and the "larger than N KiB" check reads the cap-bounded
  result (``max_output: max_bytes``, so exactly cap+1 bytes is refused —
  review N37).

The regression test runs a slow 64 MiB producer and samples the worker's
peak binary memory (``Process.info(:binary)``, reviewed N34 — the first
cut used ``:memory``, which does not see the refc binaries the output is
made of, so it was green on the bug): it stays flat (~3-16 MB, mailbox
backlog included) instead of tracking the full output, and the spill file
holds the output up to the 16 MiB cap with its in-file marker.
