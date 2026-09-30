:orphan:

Compaction: a soft idle limit, a hard reserve, and lossless summaries
=====================================================================

.. adr::
   :id: 037
   :status: Accepted
   :date: 2026-09-29
   :tags: sessions, memory, config, reliability

.. note::
   Accepted 2026-09-29; implementation landed with this record. Owner
   decisions recorded in the same session are marked *owner*. Revises the trigger
   policy of ADR 023/4b (`compaction_trigger_tokens`, an absolute 180k)
   with two limits and repairs the summarize path so compaction stops
   destroying the facts a resumed agent needs. The threshold becomes a
   percentage of the model window with an absolute reserve under the top;
   the soft limit runs while the session is **idle**, the hard limit runs
   **pre-call, busy or not**. Decision 5 (a fixed summary template and a
   carried-forward prior summary) was added 2026-09-30 after reading a
   sibling implementation; see :doc:`../explanation/compaction-strategies`.

Context
-------

Compaction (slice 4b, ADR 023) summarizes the old span of the working
context and keeps the recent tail verbatim. It has two weaknesses that
were both observed live in the 2026-09-28 review session
(``tui-14152``, a review of eight commits):

**1. The trigger is a fixed absolute (180k) that ignores the model
window, and it is not user-configurable.** ``Config.compaction_trigger_tokens/0``
reads the application env only (ADR 029 lists this as an open gap), so a
``config.toml`` key silently does nothing. The sidebar's "compacts at
180.0k tok" is therefore a constant, even for a model with a much larger
window. The review session compacted **three times** (display rows
97/98, 387/388, 798/799) in one task, each time discarding the measured
facts it had just gathered.

**2. The summarize path is lossy in exactly the way that causes rework.**
Four defects, each verified against ``tui-14152`` and the code:

a. **Tool calls, names and arguments never reach the summarizer.**
   ``Compaction.render/1`` joins only ``ContentPart.text``. Assistant
   messages carry their calls in ``tool_calls`` with ``content: []``
   (``Session`` appends ``%ReqLLM.Message{role: :assistant, content:
   [], tool_calls: ...}``), and tool-result messages carry the tool name
   in ``msg.name``; both are dropped. Measured: assistant turns rendered
   as literally ``[assistant] `` (empty), and a ``read_file`` result
   rendered as raw file text with **no path** — the path lived in the
   dropped ``tool_call`` argument. The summary cannot record *which*
   file was read, *which* command was run, or any number that existed
   only in an argument.

b. **The tail boundary splits mid-exchange.** ``split/1`` cuts at exactly
   ``length - @keep_recent`` messages with no regard for tool pairs.
   Measured on ``tui-14152``: the kept tail began with ``role: :tool``
   whose declaring assistant message fell into the summarized span — a
   wire-validity risk, and the model loses *why* the tool ran.

c. **The summarize input is unbounded and nests.** ``summarize/2`` sends
   ``render(old)`` as one un-chunked non-streaming user message.
   Measured: the old span was 193 messages / 167,868 chars (~42k tokens)
   in a single call. Because ``apply/2`` prepends the summary to the
   kept tail, the next old span contains the previous summary, so the
   input grows every cycle.

d. **The trigger under-counts the next request.** ``decide/2`` uses
   ``last_input_tokens`` from the *previous* provider call. Tool results
   produced after that call (the bulk of the growth) are not in it, so
   one large ``read_file``/``shell`` result can push the next request
   over the window between the check and the send.

The failure mode this produces is not a crash; it is **an agent that
re-derives work it already did**. The session rewrote its review
document 29 times and wrote 58 distinct probe test files, re-measuring
numbers that a fact-preserving summary would have carried.

Decision
--------

**1. The trigger is a percentage of the model window, with an absolute
reserve under the top.** *owner* Two thresholds, both derived from the
window ``W``:

- **soft** ``= round(W * soft_ratio)`` — default ``soft_ratio = 0.5``
  (the owner's "40–60%").
- **hard** ``= W - hard_reserve_tokens`` — default reserve ``64_000``
  tokens, sized to one maximum tool result (``Exec`` caps output at
  256 KiB ≈ 65k tokens at ~4 bytes/token) plus response headroom. The
  reserve is what stops "I look away and one tool call kills the
  session": after the hard limit, even a worst-case result still fits.
- **hard is floored at ``W * 0.75`` (amendment, 2026-09-30).** The
  reserve is absolute, so any window below 64k collapsed ``hard`` to 1 —
  a pre-call summarize at ~4% utilisation, degrading to a lossy trim on
  failure (review N1; the catalog has ~305 chat models under 65536).
  ``hard = max(W - reserve, W * 0.75)`` keeps the reserve absolute while
  it is at most a quarter of the window: for ``W >= 4 * reserve`` (256k
  with the default) the reserve branch governs and nothing changes;
  below that the floor governs. The trade is explicit: on a small window
  the reserve no longer covers a full 256 KiB tool result, so one
  worst-case result *could* push past ``hard`` — but ``hard`` stays well
  below ``W`` and above ``soft``, which is strictly better than a
  summarize (or a trim) firing at every call on a barely-used window.
- If ``hard <= soft`` (very small windows), ``soft := hard`` so the
  order is never inverted.

`min(absolute, …)` is *not* used: the owner's intent is that the window
scales the budget, and the reserve — not a fixed 180k — is the safety
margin. The absolute form remains available by configuring the window.

**2. The window is resolved once, with an explicit chain.** *owner*
Resolution, strongest first:

1. ``config.toml`` ``context_window`` (new layered key; project over
   global), so an uncataloged cloud model can be sized;
2. llm_db's ``limits.context`` for the model when cataloged;
3. the built-in fallback (today's ``context_window_tokens``, 500k).

The window is resolved at session init and stored on the session state
(like ``max_tool_rounds``/``reasoning_effort``), so the sidebar, the
warning and the two limits read the same number — the ADR-029 rule that
the display must not re-derive what the decision uses.

Re-resolving the window when the model changes is **out of scope here**
(*owner*: "ignore context switch for now"): a single window for the
session, resolved once, is what this ADR ships. See open question 1 for
the reminder.

**3. The soft limit fires while idle; the hard limit fires pre-call.**
*owner*

- **Hard, pre-call.** At the existing loop boundary
  (``Session.continue_loop/1``, where ``maybe_compact/1`` sits today) —
  i.e. it can interrupt a running turn. If the hard limit is crossed the
  session **must** shrink before the next provider call. It also
  corrects for defect (d): the projected size is
  ``last_input_tokens + pending-output estimate``, not the stale count.
- **Soft, idle.** After a turn ends (``complete_turn/3`` /
  ``finish_worker/2``), the session summarizes down toward the soft
  limit in a supervised background task. The user's next prompt does not
  pay the summarize latency. A **context fingerprint** guards the race:
  if a new turn started (or the context otherwise changed) while the
  summarize task ran, the summary is discarded, not applied to a context
  it no longer matches.

The hard path keeps the current failure containment (task, no link,
budgets, backoff). New: **on hard-limit failure the session degrades to
a deterministic trim**, dropping the oldest complete exchange(s) until
under the limit with a loud warning — a lossy-but-safe fallback, because
proceeding over the window is the one outcome the reserve exists to
prevent. The soft path may simply defer (back off) on failure: it is an
optimization, not a gate.

**4. Compaction must preserve facts, not prose.** *owner* The summarize
path is repaired so a resumed agent does not redo measured work:

- ``render/1`` includes, per message, the tool **name** and a compact
  rendering of the call/arguments for assistant messages, and the tool
  name for tool results — so "read ``lib/foo.ex``" and "ran ``glob
  '[a]*needle*'``" survive. Long arguments/results are truncated with an
  explicit marker, never silently dropped.
- ``split/1`` **snaps to a boundary**: the kept tail starts at a complete
  exchange (a user turn, or an assistant call with all its tool
  results), never between a call and its result. This also fixes (b).
- The summarize **input is bounded** and the instruction is reframed to
  demand facts — files touched, exact commands and their outcomes,
  numbers measured, decisions and promises — over narrative. (c)
- The tail is no longer a fixed 6 messages; the cut is snapped to a
  **complete exchange** boundary, keeping at least ``min_keep`` (6)
  recent messages, so the freshest reasoning survives without tearing an
  exchange apart.

**5. The summary is a fixed template and ROLLS FORWARD (amendment,
2026-09-30).** *owner* After reading how a sibling (opencode 1.18.33)
compacts — recorded in :doc:`../explanation/compaction-strategies` — the
free-form summary instruction is replaced by two changes, both prompt
and plumbing, no new mechanism:

- **A fixed section template.** The summarizer is told to output one
  Markdown shape (Objective / Important Details / Work State
  {Completed, Active, Blocked} / Next Move / Relevant Files), **keep
  every section even when empty**, use terse bullets, preserve exact
  paths/symbols/commands/error strings verbatim, and **not mention the
  summary process**. The structure is what makes "the right things"
  survive: every category is considered, so a fact cannot be dropped
  merely because the model did not think to include it. A resumed agent
  also reads one stable shape instead of an arbitrary prose blob.
- **The prior summary is carried forward.** ``Compaction.prior_summary/1``
  finds the existing synthetic summary message, and
  ``Compaction.summary_prompt/2`` folds the new span into it: *"carry
  forward objectives, constraints, decisions … even when the conversation
  does not mention them; where they conflict, the conversation wins; the
  prior summary is discarded after this, so anything you do not carry is
  lost."* Before this, each compaction re-derived from the span at hand,
  so a fact recorded in an early summary could vanish on the third pass —
  exactly what the review session (three compactions, ADR 037 Context)
  suffered.

``Compaction.render/1`` skips a summary message when rendering the span,
so the prior summary is never re-summarized as if it were new material;
it is carried separately, in its own ``<prior-summary>`` block. The
template is a stable contract, so it lives as a pure function
(``Compaction.summary_prompt/2``) testable without a provider.

Mechanism
---------

- ``Core.Config`` gains ``compaction_soft_ratio`` and
  ``compaction_hard_reserve_tokens`` (layered, like the other runtime
  knobs) and ``context_window`` (layered), and ``Config.compaction_trigger_tokens/0``
  is replaced by ``soft_limit/1`` / ``hard_limit/1`` computed from the
  resolved window. One reader stays (``Session.Compactor``), and the
  sidebar renders those.
- ``Session.State`` carries the resolved ``context_window`` and the
  derived limits, so a resume does not re-read config the way
  ``max_tool_rounds``/``reasoning_effort`` already do not.
- ``Session.Compactor`` gains three entry points: ``maybe_compact/2``
  (hard, pre-call), ``maybe_compact_idle/2`` (soft, background) and
  ``compact_now/2`` (manual, below the limits). All reuse the existing
  plan/apply/summarize/backoff machinery; the background ones share the
  fingerprint guard and one broadcast.
- Manual compaction ships as ``/compact`` / ``ctrl-x c`` (ADR 034) and
  ``Session.compact/1``: the human's on-demand verb, refused mid-turn
  (a boundary verb like ``/undo``). It ignores the limits — "is it over
  a threshold?" is the wrong question once the human asked — and runs in
  the same background slot as the idle pass, so the reply means
  "started", not "summarized".
- Both background tasks run under the existing
  ``Compactor.TaskSupervisor`` (never linked to the session), like the
  current summarize call.

Consequences
------------

- Compaction happens **later** on large-window models and **earlier and
  more predictably** than a 180k constant would suggest: soft at 50% of
  the real window. Fewer compactions means fewer chances to lose facts,
  which is the point.
- The hard limit is a true safety net: with the reserve held back, a
  single maximum tool result cannot overflow the window mid-turn.
- An idle session that crosses the soft limit spends provider time
  summarizing; a user who immediately prompts again pays nothing (the
  hard path covers that case, and the fingerprint discards stale work).
- The summary becomes genuinely useful as mid-term memory: it carries
  tool/command/file facts, which is exactly what the lossy version
  dropped.
- Cost: two thresholds and a background task are more moving parts; the
  fingerprint guard is the subtle piece and needs its own tests.

Open questions
--------------

1. **Per-model windows on model switch — RESOLVED (2026-09-30, review
   N9).** The session may switch models mid-life (the model menu) or an
   agent may pin one (ADR 017), and different models have different
   windows. Originally the window was resolved **once at init** and the
   switch was ignored, so the limits kept describing the old model — now
   visible in the prompt (ADR 040), and a 128k→16k switch left the
   session budgeting against 128k while the provider rejected at 16k.
   ``Session.recompute_window/1`` now re-resolves on every effective-model
   change: ``apply_model/2`` (both the idle ``set_model`` path and the
   turn-boundary switch) and the agent switch (a pinned model, ADR 017)
   all call it, sharing one path with the catalog-ready re-resolve. The
   sidebar/budget block update via the same ``{:context_window, …}``
   broadcast. Still open within this question: whether a per-model table
   (``[context_windows]``) is wanted; the single key plus catalog suffices
   for now.
2. **Chunked summarization.** Bounding the input by chunking the old
   span (multiple summarize calls, hierarchical) versus one call with a
   hard character cap. Chunking preserves more but multiplies the
   latency/cost; the cap is simpler but is itself lossy. Deferred: first
   measure how large old spans actually get with the boundary-safe tail.
3. **Nested summary growth.** Each summary is summarized again on the
   next cycle. Should a prior summary be compressed separately (a
   dedicated "summarize the summary" prompt) or merged as ordinary
   text?
4. **Idle timing.** How long idle before the soft pass starts? An
   immediate pass may race a fast follow-up prompt; a delay adds a
   timer. The fingerprint makes correctness independent of the choice,
   so this is a latency/tuning question.
5. **Reserve sizing.** 64k tokens is derived from the 256 KiB output
   cap. If the cap changes (or a provider's own output ceiling differs),
   the reserve must follow; is the reserve better expressed as
   ``exec_cap_bytes / 4`` than as a free-standing token count?
