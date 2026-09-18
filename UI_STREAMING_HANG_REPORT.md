# Report: The streaming/input interaction hang — analysis and proposal

**Author:** [review reviewer]
**Status:** IMPLEMENTED (4.1, 4.2, 4.3) — see closure note at the end
**Scope:** the recurring "I can't interact with the program while it works/streams" problem.

This report documents the root cause, what the current fix (`drain_deltas`,
commit `686acd6`) achieves and what it leaves open, and the architectural
changes I believe are required. The aim is a *clean* architecture, not a
band-aid.

---

## 1. The environment we are building on

`ex_ratatui` runs the whole TUI in ONE server process (`ExRatatui.Server`).
The per-frame loop is:

```
handle_info(:poll) ->  poll_event(16ms)   (crossterm NIF, up to 16ms)
                   ->  handle_event/2    (typed keys, clicks)
                   ->  do_render/0        (full render, all widgets)
                   ->  send(self(), :poll)  (re-arm)
```

Consequences, all structural:

- **Keystrokes and rendering share one process.** While `do_render/0` runs,
  the server cannot process any key event. Incoming bytes sit in the
  crossterm poll until the render returns, then arrive in a burst. That is
  the user symptom: *"typed text hangs somewhere and is shown later."*
- **Every callback can opt out of a render** with
  `{:noreply, state, %{render?: false}}`. This is the designed throttle/render
  control. `do_render` happens on the next `:poll`. This is the lever the
  fix should have used and did not.
- There is no separate input reader. (A long-term design could add one — see
  section 5.)

## 2. Root cause (confirmed by two independent analyses + live report)

A reasoning model emits a stream of many small deltas. Until recently the TUI
re-rendered the **full markdown transcript once per delta**. A 500-delta burst
blocked `:sys.get_state` past 5 s — typed keys and ESC sat in the mailbox
behind a render train.

There are **two separable causes**, and the current fix addresses only the
first:

### 2a. Too many renders per stream (the burst)

Every `{:llm_deltas, _}` / `{:reasoning_deltas, _}` message produced a full
render. This is what `drain_deltas/2` now solves.

### 2b. Each render is O(n²) over the stream (the per-frame cost)

Even after coalescing, every render re-does expensive, accumulating work:

1. `display_entries/1` and `streaming_entries/1` call `render_reasoning(text)`
   on the **entire accumulated** reasoning/answer text every frame, which runs
   `harden_line_breaks/1` (`String.split` + `Enum.map_reduce` + `join`) over
   all lines. Per frame that is O(total length); over the whole turn it is
   O(n²).
2. The height-measure cache (`TranscriptView.painted_height/2`) is keyed on
   `:erlang.phash2(widget)`. The streaming Markdown widget's `content` changes
   with every delta, so the cache misses every frame, re-running the
   400-row headless terminal probe (`init_test_terminal` + native draw) per
   miss — again over the growing text.

So: **once a stream is long enough that even one coalesced render is
expensive, the interaction hang returns.** The current fix has only widened
the time window, not removed the mechanism.

## 3. On `harden_line_breaks/1` and consecutive-newline collapsing

There are two distinct things that the code and its comment conflate. One
must stay; one is genuinely removable. The comment currently implies the
wrong separation.

### Must stay: `harden_line_breaks/1` (visual line structure)

CommonMark / the markdown renderer treats a **single `\n` as a soft break** —
it becomes a space and two lines *flow together* ("line one line two" in one
visual line). The two-trailing-spaces sequence is a **hard break** that forces
a visual line boundary.

A reasoning trace is line-structured (one line per thought). Rendered as
markdown without the harden step, every thought would glue to the next
(only separated from runs by blank lines). So **`harden_line_breaks/1` is not
a band-aid; it is the one thing that keeps reasoning lines as lines.**
Removing it would change the visual output and regress code fences (the
function's fence-skip is what keeps ` ``` ` blocks intact).

### Genuinely removable / already obsolete: consecutive-newline collapsing

The *"runaway blanks"* behavior (GLM sending `"l1\n"` + `"\n"` as separate
deltas → `l1\n\n`) was a **Paragraph-era** problem. The markdown renderer
**collapses runs of blank lines to one paragraph break by itself.** So the
comment's claim `render_reasoning still trims trailing newlines … so the
runaway cannot grow the box` is describing an obsolete Paragraph-era fix.
This is the part your instinct correctly tagged as removable.

### The `String.replace_trailing("\n", "")` trim is NOT a band-aid either

The trailing-`\n` trim in `render_reasoning/1` maintains a **buffer/display
consistency contract**: `streaming_entries/1`, `persist_reasoning/1` and
`normalize_entry/1` rely on the displayed string never ending in `\n`, because
a trailing newline becomes a phantom empty row in the window math (the
`scroll up three screens of blanks` bug). If removed, the `\n`-consuming paths
must compensate. The comment's *reasoning* is stale (it cites Paragraph), but
the *norm* itself is load-bearing.

**Action:** keep `harden_line_breaks` and the trailing trim; the real fix is
to stop re-running them per frame (section 4.2) and to correct the comment.

## 4. Proposal

### 4.1 Use `render?: false` + a render throttle instead of `drain_deltas`

`drain_deltas/2` is a band-aid and, architecturally, the wrong tool:

- It **blocks the app callback** with a `receive … after 0` loop up to
  `@delta_batch_max`. During that loop the server processes nothing else. A
  *steady trickle* (delta; delta; delta; … — exactly what a reasoning stream
  looks like) means the `after 0` rarely fires, so keys wait behind the loop
  again: the same hang, with a bigger time budget per render.
- It reaches **into the server's mailbox** from the user module. The runtime
  provides `render?: false` precisely to let the app defer rendering without
  stealing messages.
- `@delta_batch_max 2_000` is an arbitrary constant chosen to make the
  500-delta test pass; it does not guarantee interactivity for a real stream.

**Proposed shape:**

- On `{:llm_deltas, _}` / `{:reasoning_deltas, _}`: fold the delta into
  `state.stream` and return `{:noreply, state, %{render?: false}}`.
- Separately (e.g. a timer or on the next `:poll`), render at most every
  ~50–100 ms while streaming. Input is then handled in the normal loop
  between throttled renders; no `receive` in the callback; no arbitrary cap.

This keeps the app non-blocking and respects the ex_ratatui contract. It also
makes the `drain_deltas` logic (and its test) obsolete or much simpler.

### 4.2 Take the O(n²) render path away

Two changes:

1. **Do not re-harden the whole stream every frame.** Keep the normalised
   (harden + trailing-trim) form in the `stream` state, and re-derive it once
   per **delta batch** (`append_stream`), or only re-run the block whose tail
   changed. The fence handling makes a pure tail-push non-trivial, so a
   per-batch full re-harden of the **streaming blocks only** is acceptable
   (bounded by stream growth per batch, not per render).
2. **Do not measure a growing streaming widget per frame.** Either track the
   last measured height and add the increment for newly arrived lines, or
   measure the *added* content separately. This removes the
   `init_test_terminal` + native-draw probe from the per-frame hot path.

### 4.3 Correct the comment

`render_reasoning/1` / `harden_line_breaks/1` should state the real contract:
markdown soft-break line structure (keep) vs. obsolete Paragraph-era blank
collapsing (remove). The trailing-trim norm should be documented as a
buffer/window-consistency invariant, not a Paragraph fix.

### 4.4 (Long-term) separate the input from the render loop

The durable architecture is an **input reader on its own lightweight process**,
feeding keys into the app's mailbox, decoupled from rendering. ex_ratatui's
local transport today reads and renders in the same server. This is the larger
change; worth doing after 4.1–4.2 confirm the fix, because 4.1/4.2 solve the
reported symptom with low risk today.

## 5. What I am NOT recommending

- Removing `harden_line_breaks` outright: it is load-bearing for reasoning
  line structure. (Only its *per-frame re-execution* is a problem.)
- Keeping the `receive`-in-callback coalescing as the solution.

## 6. Suggested sequence

1. Implement 4.1 (`render?: false` + throttle) — smallest safe behaviour fix,
   removes the mailbox-peek.
2. Implement 4.2 — removes the O(n²) cost so a *long* stream stays cheap.
3. Update/remove the `drain_deltas` test accordingly; add a throttle test
   that asserts keys are handled *during* a stream (not just after it).
4. Correct the comment (4.3).
5. Consider 4.4 as a follow-up.

The regression test for 4.1 should assert interactivity *mid-stream* (a key is
handled while deltas keep arriving), not only that a burst completes under a
time budget.

---

## Verification notes (current state)

- `mix test`: 527 passed. `tui_stream_burst_test.exs` passes (burst absorbed).
- The burst test measures wall time for a 500-delta burst and asserts the
  key reaches the textarea *afterwards*. It does not exercise the tricky
  case of keys issued *while* steady small deltas continue.

---

## Closure note (implementation)

Implemented 4.1 + 4.2 + 4.3. All claims held up except one detail worth
recording for future readers:

- **§2b.2 is wrong as written.** The report claims the height-measure cache
  miss re-runs the 400-row `init_test_terminal` probe *"over the growing
  text"*, i.e. O(n²). Measurement showed the probe cost is essentially
  **constant** (~6–9ms at 50→400 reasoning lines): the fixed 400-row
  allocation + native draw dominates, not the text length. The real
  accumulating cost is `render_reasoning/1` over the whole text **per
  frame** (O(n) per frame = O(n²) per turn) — which the throttle now
  bounds to ~16 frames/s, and which the duplicate per-frame call in
  `entry_widgets/3` no longer repeats.
- The proposed throttle mechanism (`render?: false` + separate tick) was
  correct. One refinement: `handle_poll_result(nil)` itself returns
  `render?: false`, so the next `:poll` does **not** paint — a timer is
  mandatory, not optional. The implementation uses `subscriptions/1`
  (`:stream_render`, 60ms) rather than a bare `send_after`, so the timer
  retires while the stream is quiet and re-arms on the next delta.
- `drain_deltas/2` and `@delta_batch_max` are deleted.
- New test asserts the three properties: a delta defers (no paint until
  the tick), the subscription is declared only while dirty, and a key is
  handled **mid-stream** while deltas keep arriving.
