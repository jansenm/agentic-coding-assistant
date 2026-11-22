.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

Transcript measurement: lazy, tail-first, not eager
===================================================

.. adr::
   :id: 028
   :status: Accepted
   :date: 2026-09-23
   :tags: ui, performance, sessions

.. note::
   Accepted and implemented 2026-09-23. Responds to a live observation:
   opening the long-lived session in the TUI takes "longer and longer".
   The cause is measured — the transcript height is re-measured
   **eagerly over the whole session on every frame that misses the
   cache**, and the cold cache for a 1630-entry session costs **8–12
   seconds**. The decision: measure lazily from the tail, only what a
   viewport needs. No schema change, no precomputation in the store.

   **Implemented.** ``TranscriptView.viewport/5`` walks backwards from
   the tail, measuring only until it covers the window, and returns
   ``{clamped_offset, [{entry, pane_relative_top, height}]}`` —
   pane-relative, so the renderer and the hit-test no longer compute an
   absolute transcript total. ``TranscriptView.total_height/3`` stays as
   the eager/test primitive: the render, clamp, hit-test and diagnostics
   paths stopped calling it (the diagnostics line reports the clamped
   offset, from the same lazy walk), so in the shipped tree its only
   caller is the differential test that reconstructs the old eager
   algorithm (``transcript_view_test.exs``, "differential: the lazy walk
   == the eager algorithm it replaced" — no production path calls it).
   The stored ``max_scroll`` is gone: the viewport
   returns the accepted offset, and the scroll handlers clamp through it.

   **Measured result** (live session, 1630 rows, cold cache):
   11.6 s → **52 ms** for the visible window. A differential test against a
   reconstruction of the old eager algorithm confirms **identical
   entries, positions and clamping** across offsets and pane sizes.

   **A regression the implementation found.** The first version clamped
   the pane top to the content's own top only when content was shorter,
   but computed the wrong edge for content shorter than the pane,
   floating it at the bottom instead of top-anchoring it. The existing
   accordion hit-test caught it (a click on the first entry stopped
   resolving); fixed and pinned by "short content sits at the pane TOP".
   The differential test now covers the short case and an expanded tool
   (an ``open_id`` changes measured heights) as well.

Context
-------

`Tui.transcript_widgets/2` calls `TranscriptView.total_height/3` every
frame to clamp the scroll offset, and `TranscriptView.viewport/5` calls
it a second time. `total_height` sums `height/3`, which **paints each
widget into a headless terminal and scans the buffer** for the last
non-blank row (`painted_height/2`). It is exact by construction — the
measurement IS the render — but it is a NIF draw per widget.

Measured on the live session `tui-5250` (1630 display rows, 2.2 MB of
tool output + 4.4 MB of reasoning):

.. list-table::
   :header-rows: 1

   * - operation
     - cost
   * - ``Store.load/1``
     - 16 ms
   * - ``Store.display/1``
     - 18 ms
   * - ``total_height`` cold
     - **8.3–9.6 s**
   * - ``total_height`` warm
     - ~10 ms
   * - warm frame (new entry)
     - 9 ms
   * - warm scroll frame
     - 21 ms

Per entry type (cold): 916 collapsed tools at 4 ms each (4.1 s), 648
reasoning at 8 ms (5.2 s), 88 assistant at 5 ms (0.5 s). The cost is
**linear in session length** — exactly the reported "longer and
longer".

Two properties drive the design:

- **Height depends on the terminal width.** Measured: one assistant
  entry is 104 rows at 60 columns and 72 at 160. Wrap, not line count.
- **The scroll model is tail-anchored.** `scroll_offset` counts lines
  above the bottom edge; `0` follows the tail. A 30-row pane displays
  **3** entries of this session. The renderer never needs the whole
  transcript's height — only enough of the tail to fill the pane.

Why not precompute heights in the store
---------------------------------------

Storing a `height` column in the display table does not work directly:
height depends on width, and width is a per-render property. A height
keyed to a width is invalidated by every resize; a height keyed to no
width is wrong.

A variant would work — collapsed tool entries are a **constant 4 rows at
every width** (measured at 60/80/96/120/160), so a `fixed_height` or
`wrap?` column would let SQL sum ~56% of this session's rows exactly —
but it puts a TUI layout concern in the store schema, against ADR 008
(`Core.*` has no UI deps), and it only helps the cold path that the lazy
design removes anyway. The measurement cache belongs in the render
layer, keyed on content, next to the painting it mirrors.

Decision
--------

**1. The viewport measures lazily from the tail.** `viewport/5` walks
backwards from the last entry, measuring (through the existing
content-keyed cache) only until it has covered `offset + pane_height`
lines. It stops there. Entries above the viewport are never measured
until the user scrolls to them.

Measured: a cold tail-first fill for a 30-row pane costs **67 ms**
against 9.6 s eager — and returns the same pixels.

**2. The clamp becomes lazy too — "at the top" is discovered, not
precomputed.** The current clamp needs `total_height` to compute
`max_offset`. The lazy walk instead reports whether it ran out of
entries before covering the requested span:

- not exhausted → the offset is valid, no maximum is known (or needed);
- exhausted → the viewport has reached the top, and the walk's
  accumulated line count IS the total, so `max_offset = total -
  pane_height` exactly.

`scroll_offset` therefore no longer needs a precomputed `max_scroll` to
be clamped. Scrolling up extends the measured region by one screenful
per keypress — the work is proportional to what the user actually
looks at, which is the point.

**3. The scroll coordinate returned is pane-relative.** The viewport
returns each visible entry's offset from the pane top (negative when the
entry starts above it). The renderer's `rel = cursor - top` dance and
its dependency on an absolute transcript origin disappear; the placement
math is simpler and there is no total to subtract.

**4. Measurement stays width-keyed and content-keyed, unchanged.**
`painted_height/2`'s cache key `{phash2(widget), width}` already makes a
warm frame cheap (9–21 ms) and a resize a cold miss. The lazy walk
simply means a resize re-measures only the visible window (~67 ms), not
the session.

**5. `total_height/3` stays, as the eager/test primitive.** After this
change nothing on a production path calls it — the diagnostics line
reads the clamped offset from the lazy viewport like the render, clamp
and hit-test do. What keeps it alive is the differential anchor: it is
the reconstruction of the old eager algorithm that the lazy walk is
checked against, so it must keep measuring the whole transcript, eagerly,
by exactly the path the old code used. That anchor is an in-tree test
(``transcript_view_test.exs``), not a scratch probe, so the check
survives; without it the function is dead weight and could be removed.

Consequences
------------

- Cold start of the long session: 8–12 s → **52 ms** for the visible
  window (measured after implementation). Resize: same — re-measures only
  the visible window. Streaming a new entry and scrolling stay O(visible ×
  cache-hit) rather than O(session).
- Scrolling into history measures as it goes: bounded work per
  keypress, proportional to the lines revealed. There is no jump-to-top
  binding today, so no path forces a full measure in one frame.
- The coordinate system gets simpler (pane-relative), and the render
  path no longer computes a quantity (the absolute total) it never
  needed to paint.
- No schema change, no store coupling, no migration. The store's display
  view stays a plain-text record (ADR 020).
- The cache remains process-local ETS created lazily. A cold process
  still pays one probe per entry it actually displays; it no longer
  pays for the ones it does not.
- There is no `max_scroll` field: the maximum exists only as a local
  value inside the walk that reached the top. The mouse/scroll-up
  handlers clamp through the lazy walk instead of a stored maximum.

Open questions
--------------

1. Should the *rest* of the transcript be pre-warmed in the background
   after mount (a chunked task that yields, so it never blocks a
   scheduler), so scrolling up is instantly warm? It trades idle CPU for
   scroll latency; the lazy walk may make it unnecessary.
2. Should a jump-to-top binding (ctrl-home, opencode-style) exist? If
   it does, it must measure the whole transcript in one frame by
   construction — a reason to pre-warm, or to budget the measurement
   across a few frames (top reached progressively).
3. Should collapsed tool entries keep their constant-height fast path
   (4 rows, measured) to skip the probe entirely for that 56% of rows?
   A cheap win inside the cache, not a schema change.
