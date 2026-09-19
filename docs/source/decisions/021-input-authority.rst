:orphan:

Input events: one authority (classify then drop)
=================================================

.. adr::
   :id: 021
   :status: Proposed
   :date: 2026-09-19
   :tags: ui, input, keymap, textarea, bugfix

.. note::
   Proposed 2026-09-19. Responds to a review finding (the 2026-09-19 UI
   review, finding D; commit ``bbd7f2f``) that the input pipeline has
   **two authorities** — our ``Keymap`` and the textarea crate's own
   Emacs bindings — and that the raw event is forwarded to the crate, so
   whatever the keymap does not intercept is executed with different
   semantics. This ADR is the design for removing that class of bug;
   the small safety nets around it (modifier fallback, action coverage)
   shipped with the review fixes.

Context
-------

Input flows through three stages today:

1. ``Bridge.translate/2`` classifies a terminal event as ``{:key, e}``
   (a keymap candidate) or ``{:text, s}`` (everything else).
2. ``Keymap.resolve/2`` maps a keymap event to an action atom.
3. ``Tui.dispatch_input_key/3`` handles the actions it knows and, for
   *everything else*, calls ``forward_to_textarea/2`` with the **raw**
   event.

Stage 3 is the problem. Of the 19 actions ``Keymap.defaults/0``
declares, only 10 have a clause; the other 9 (``:cursor_home``,
``:cursor_end``, ``:cursor_up``, ``:cursor_down``, ``:cursor_left``,
``:cursor_right``, ``:kill_to_end``, ``:kill_word``, ``:kill_line``) are
performed by the crate when the raw event is forwarded. The keymap's
claims for those keys are therefore **decorative**, and any divergence is
invisible until a user hits it. Measured live (review D):

.. list-table::
   :header-rows: 1

   * - key
     - keymap claims
     - crate actually does
     - result
   * - ``ctrl-j``
     - ``:insert_newline``
     - ``delete_line_by_head``
     - typed line **wiped**
   * - ``ctrl-u``
     - ``:kill_line``
     - ``undo``
     - typed text **wiped**
   * - ``ctrl-k``
     - ``:kill_to_end``
     - ``delete_line_by_end``
     - passes by coincidence
   * - ``ctrl-w``
     - ``:kill_word``
     - ``delete_word``
     - passes by coincidence

The wildcard ``_ -> forward_to_textarea`` also means a *new* action, or
an action the keymap binds but the TUI does not handle, silently becomes
raw text instead of raising. This is the same bug class as B2 ("typed
text disappears"): **two components, one keystroke, no single owner.**

Two partial mitigations are already in the tree and stay:

- ``Keymap.resolve/2`` now has a modifier fallback lattice
  (specific-before-generic), so a shifted special falls back to its
  plain binding instead of going ``:unbound`` (review B).
- ``InputActionCoverageTest`` asserts every declared action is either
  handled or listed as *explicitly delegated*, so a new action cannot
  fall through silently (review D, tripwire).

Those make the current split safe *to observe*; they do not remove it.

Decision
--------

**One authority: ``Bridge`` classifies, and a raw event is never
forwarded.** Each terminal event resolves to exactly one of:

- ``{:text, s}`` — a text insertion, performed by exactly one sink;
- ``{:command, intent}`` — a resolved intent (an action atom from the
  keymap, or a textarea movement/edit intent), performed by exactly one
  executor;
- ``{:ignored, reason}`` — an event with no meaning; dropped, with the
  reason observable (trace/debug), never silently turned into text.

The rule that kills the class: **the raw ``%Event.Key{}`` stops at the
boundary.** It is never passed to the textarea. The crate's key handling
(``textarea_handle_key/3``) is either driven by an explicit intent →
crate mapping in one executor, or not used for input at all (see
*Options*).

Concretely:

- ``Bridge.translate/2`` becomes the single classifier. Its decision is
  the *only* thing downstream code acts on.
- A textarea intent vocabulary is defined (``:insert_text``,
  ``:newline``, ``:cursor_left`` … ``:kill_line``, plus a selection
  family if shift-arrows are to mean selection). ``dispatch_input_key/3``
  maps keymap actions to these intents; its handled set *is* the intent
  set.
- One executor applies intents. Whether it calls the crate's NIFs or
  implements the edit in our own buffer is an implementation choice
  behind that seam — and is where the crate's divergent semantics get
  normalized (``ctrl-j`` means newline because *we* say so).

This also makes the keymap honest: every action it declares has exactly
one executor, and the coverage test has no "delegated" second list to
excuse.

Options for the executor
------------------------

1. **Normalize onto the crate.** The executor maps our intents to the
   crate's NIFs, choosing the NIF whose behavior matches the intent
   (never forwarding the key). Lowest risk, keeps the crate's editing
   (undo, selection). Requires auditing each NIF's real semantics once —
   the review already produced that table.
2. **Own the buffer.** Replace the crate's key handling with our own
   text model. Full control (wrap, selection, kill-ring), but it is a
   text-editor component — the same machinery ADR-track B5 (input wrap)
   would need. Larger.

Recommendation: **option 1 now** (it deletes the class with contained
risk), and revisit option 2 if/when B5 (soft wrap) forces an own-buffer
anyway. The two are not exclusive: option 1 is a stepping stone with the
intent vocabulary already in place.

Consequences
------------

- ``ctrl-j``/``ctrl-u`` and any future keymap/crate divergence become
  impossible: there is one owner per keypress.
- The coverage test gains teeth — the ``@delegated_input_actions`` list
  is deleted, because nothing is delegated any more.
- ``shift+tab`` (crossterm ``back_tab``) can be bound deliberately rather
  than as a side effect (it was unbound before and after this work).
- Small cost: an explicit intent vocabulary and an audit of every
  intent's crate behavior; the review's table is the starting point.
- ``Bridge`` grows a vocabulary, so it is no longer a pure translation
  table — it becomes the *classification* boundary. That is the point.

What is NOT decided here
------------------------

- Whether shift-arrow means selection (a real editor feature) or is
  ignored. That belongs to the intent vocabulary once it exists.
- The B5 soft-wrap design, which may later replace the executor's
  internals (option 2).
