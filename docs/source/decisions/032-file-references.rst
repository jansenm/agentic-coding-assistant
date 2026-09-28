:orphan:

File references: `@` opens a confined file picker
==================================================

.. adr::
   :id: 032
   :status: Accepted
   :date: 2026-09-28
   :tags: ui, tools, input, sandbox

.. note::
   Accepted and implemented 2026-09-28. Answers B3 in ``TODO.md`` (the
   last open dogfooding blocker). Typing ``@`` at a word boundary in the
   composer opens a bottom-anchored, live-filtered file picker; choosing
   a file inserts ``@<relative-path>`` into the prompt. The list comes
   from a confined ``fd`` (ADR 030), never a BEAM walk.

Context
-------

Referring to a file while prompting is the missing half of "let the
agent read the code": the model can already ``read_file`` any path the
profile exposes, but the human has to type the path from memory. The
dogfooding notes call this B3, and ADR 030 anticipated it directly:

  A file reference/autocomplete feature can offer any path the session
  can actually read (``TODO.md`` B3), because the reach is uniform.

Two constraints shape the decision:

1. **The list must come through the sandbox.** ADR 030 deleted the BEAM
   walk: a ``hide``/``ro`` grant is enforced by the profile, so a picker
   that enumerated the tree in the BEAM would show paths the session
   cannot actually read (and would re-open the second boundary this ADR
   family closes). The list is a confined ``fd`` run.
2. **The composer is text.** There is no attachment channel: ``send_input``
   passes the trimmed buffer as one string to ``Session.run/2``. Inserting
   text is therefore free; attaching *content* is a new prompt pipeline.

Decision
--------

**1. ``@`` at a word boundary opens a file picker.** The trigger is a
literal ``@`` typed when the character before the cursor is whitespace or
the start of a line (opencode's rule). The trigger is TEXT, not a keymap
action (ADR 011/021): ``@`` is an ordinary character, and treating it as
a binding would make it untypable mid-word. Detection reads the textarea
buffer and cursor immediately before the insert.

**2. The picker is a bottom-anchored popup, reused from the menu.** It
uses the same overlay geometry as the ctrl-x menu (``overlay_rect`` above
the live band, windowed list with an absolute selection marker), so it
never covers the composer and a long list windows instead of clipping.
It is live-filtered: every typed character narrows the list by a
case-insensitive substring of the relative path, the same filter the
sessions picker uses.

**3. Choosing a file inserts its path, not its content.** The selected
``lib/foo.ex`` replaces the ``@<query>`` in the buffer with
``@lib/foo.ex `` — a reference the human can see and the model resolves
with ``read_file``. No content is pulled into the prompt: there is no
channel for it, and pre-reading would duplicate the model's own
``read_file`` and burn context the model may not need. Attaching content
is left as an open question, explicitly requiring a new pipeline.

**4. The list is a confined ``fd`` (ADR 030).** A new
``Core.Tools.ListFiles.list/1`` runs ``fd`` through ``Core.Exec`` under
``Tools.profile/1``, with the shared skip-dir excludes and the same
result filter as ``glob`` (``Tools.in_scope?/2`` plus the hidden rule),
so the picker offers exactly what a search would report. The TUI builds
the scope from the live session (``Session.state/1`` +
``ToolRunner.scope/5``) so ``mounts``/``shell_mode``/``session_id`` apply
— not a bare root. A missing ``fd`` is a clear note, not an unconfined
fallback.

**5. Hidden entries follow the one naming rule.** The fetch includes
hidden entries (``--hidden``); the picker filters them with
``Containment.hidden_allowed?/2`` and the current query. A query that
names a hidden segment (``@.github``) reveals them; a plain query does
not. This is the same "naming is the opt-in" rule ``grep``/``glob`` use,
so there is no second hidden vocabulary.

Consequences
------------

- Referring to a file costs a few keystrokes, and the offer is exactly
  the reachable set — ``hide``/``ro`` hold because the list came from the
  profile.
- The list is fetched ONCE when the popup opens and filtered in memory;
  typing does not spawn a process per keystroke. A stale list (a file
  created mid-prompt) is accepted for v1.
- ``External`` gains the shared ``exclude_args/0`` (the
  ``**/<dir>/**`` shape) that ``glob`` and the picker both use, so the
  two cannot drift.
- Content attachment, multi-selection, and directory references are not
  offered. The inserted token is an ordinary path: the model is expected
  to ``read_file`` it.

Open questions
--------------

1. **Attach content?** A ``@file`` that inlines the file would need a
   prompt/payload channel through ``Session.run/2`` and a rule for
   truncation (``read_file``'s 256 KiB cap?) and re-reads. Deferred until
   dogfood shows path references are not enough.
2. **Directory references / ``@dir/`` drill-down.** v1 lists files only;
   a trailing ``/`` could descend. Not scheduled.
3. **Fuzzy vs substring.** The first filter is a case-insensitive
   substring (the picker's rule). Fuzzy matching (opencode uses it) is a
   later refinement if substring proves too literal on deep trees.
