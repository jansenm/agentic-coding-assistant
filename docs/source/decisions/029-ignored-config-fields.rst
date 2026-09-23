:orphan:

Ignored configuration fields: wire them or fail loudly
======================================================

.. adr::
   :id: 029
   :status: Accepted
   :date: 2026-09-23
   :tags: config, agents, sessions, prompts, providers

.. note::
   Accepted and implemented 2026-09-23. Closes the ``hidden`` half of T3
   in the ``code_review.md`` "rival opencode" list and removes the last
   documented-but-dead knobs: ``reasoning_effort`` (config.toml), and the
   agent fields ``hidden`` and ``mode: all``. The rule that ADR 024/025
   applied to ``temperature``/``maxTurns`` — a documented field that
   changes nothing is a lie in the docs — is now a standing property of
   the configuration surface, with a loud failure where a value cannot
   be honoured.

   **Implemented.** ``Config.reasoning_effort/1`` resolves the layered
   ``reasoning_effort`` (project over global) or the app env into
   req_llm's canonical atom, and **raises** on an unknown value;
   ``State.reasoning_effort`` carries it; ``wire_request/2`` puts it on
   every request; the sidebar renders the session's resolved value
   instead of a global re-read. ``Agent.selectable?/1`` is the single
   rule for human-selectable definitions (``:primary`` or ``:all``, and
   not ``hidden``); the TUI's Tab list and the session's resume guard
   both read it, so a ``mode: all`` definition is no longer silently
   dropped and a ``hidden`` one is no longer offered.

Context
-------

Three fields were parsed and then consumed nowhere, or only for
decoration:

1. **``reasoning_effort``** (``config.toml``, ADR 014) was read by
   ``Core.Config.reasoning_effort/0`` and by the TUI — but the TUI read
   it *only to render the sidebar*. The request builder never saw it, so
   a user could set ``reasoning_effort = "high"`` and watch the sidebar
   print ``effort: high`` while the provider received nothing. This is
   worse than an unknown key: the UI confirmed a setting that had no
   effect.

2. **``hidden``** (agent frontmatter, ADR 017) was parsed into
   ``Core.Agent`` and read by no one. OpenCode's schema annotates it
   "Hide this subagent from the @ autocomplete menu", and its agent
   resolution excludes hidden agents from the default agent; we have no
   @ menu yet, but the Tab cycle is our selection surface today.

3. **``mode``** *was* consumed — by a filter that read
   ``mode == :primary``. Since the parser defaults an absent ``mode`` to
   ``:all`` (the standard's default), any definition that did not
   explicitly write ``mode: primary`` was silently invisible to Tab,
   while ADR 017 documents ``:all`` as selectable by the human.

The common failure is not a crash; it is **silence**. The system accepts
a value, acknowledges it, and behaves as if it were never there.

Decision
--------

**1. Every resolved configuration value either reaches its consumer or
fails loudly at resolution.** ``Config.reasoning_effort/1`` returns the
canonical req_llm atom (``:none | :minimal | :low | :medium | :high |
:xhigh | :max | :default``) or ``nil``, and raises on anything else,
naming the source and the accepted set. A typo is a startup error, not a
setting that silently does nothing. This is the ``no_model_message/0``
precedent applied to a knob instead of a requirement.

**2. ``reasoning_effort`` is a session-level value on the wire.**
Resolution is layered ``config.toml`` (project over global) over the
app-env seam, exactly like ``max_tool_rounds`` (ADR 025), and it rides
``wire_request/2`` as req_llm's top-level ``:reasoning_effort`` option.
Absent, no key is sent — the provider's own default stands. There is no
agent-level override: opencode's agent schema has no ``reasoningEffort``
field either, and ``temperature`` (which *is* per-agent) sets the
precedent for what a definition pins. If per-agent effort is wanted
later, it is a new field, not a reinterpretation of this one.

**3. The sidebar renders the session's resolved value.**
``state.session_effort`` is mirrored at mount from the live session, the
same way the model is. A config re-read in the sidebar would show the
global layer even when the running session honoured a project override —
the display would disagree with the wire. The sidebar's job is to report
what is happening, not to re-derive it.

**4. ``Agent.selectable?/1`` is the ONE selection rule.** True for
``:primary`` and ``:all``; false for ``:subagent`` and for ``hidden``.
The TUI's Tab list and ``Session.resumable_agent_name/1`` both call it,
so the UI and the resume path cannot disagree about who the human may
select. ``:subagent`` remains reserved for the ``task`` seam (ADR 017
question 5).

**5. ``hidden`` hides from human selection, it does not disable.** A
hidden definition is still loadable and still startable by name (the
``task`` seam will need exactly that for internal agents); it is
excluded only from the surfaces that *offer* agents to the human. This
matches opencode, whose ``hidden`` agents (``title``, ``summary``,
``compaction``) are fully functional but never offered.

Honest limits
-------------

**Not every provider honours the option, and we do not paper over that.**
req_llm treats ``:reasoning_effort`` as a canonical option and each
provider translates it: the OpenAI-family path emits
``"reasoning_effort"`` in the body (including through
``openai_compatible_backend: :ollama``, which is how ``ollama_cloud`` is
configured), native Ollama emits it as a top-level field with clamping
(``minimal`` → ``low``, ``xhigh`` → ``max``), and Google translates it
to a thinking level or budget. **Zai/Zhipu (GLM) does not**: its
provider translates ``:thinking`` maps and drops ``reasoning_effort``
from the body. A GLM user who sets ``reasoning_effort`` gets the value
displayed and validated, but not honoured, because req_llm's zai
translation does not consume it. We send the canonical option and let
req_llm own provider translation; we do not invent a per-provider map
here. This is recorded, not hidden — the fix, if wanted, belongs in
req_llm's zai provider (map effort onto its ``thinking`` shape) or in a
future provider-aware translation layer of ours.

**Compaction budgets remain app-env only.** ADR 014 lists "compaction
trigger, reasoning effort" as ``config.toml`` fields. ``reasoning_effort``
is now genuinely one; ``compaction_trigger_tokens``,
``compaction_wall_clock_ms`` and ``compaction_inactivity_ms`` are still
read only from the application environment. That is the same defect
class, out of this ADR's scope by intent (they are tuning knobs with
measured defaults and no user-visible display), and belongs to the
configuration-boundary work rather than here.

Consequences
------------

- Setting ``reasoning_effort`` in ``config.toml`` changes the request
  for every provider whose translation consumes it, and the sidebar
  shows the same value the session resolved — including a project
  override.
- A malformed value stops the session with a message naming the key and
  the accepted set, instead of running without the setting.
- ``mode: all`` definitions (the standard's default) are selectable by
  the human; ``hidden`` ones are not; ``mode: subagent`` ones are not.
  The three consumers of that rule share one predicate.
- ``hidden`` is load-bearing only once an agent is *offered*; the @ menu
  and the ``task`` tool inherit the predicate rather than re-deriving it.
- The config surface gains a test-locked invariant: every documented key
  has a consumer, and every unresolvable value fails loudly.

Open questions
--------------

1. Should ``reasoning_effort`` gain a per-agent override (a frontmatter
   field), or is session-level sufficient? ADR 017's honoured-fields
   list would need the new field named.
2. Should the sidebar distinguish "configured but unsupported by this
   provider" from "not configured"? req_llm exposes a reasoning advisory
   per provider that we currently discard; surfacing it would turn the
   GLM case from a documented limitation into a visible warning.
3. Do the compaction budgets move to ``config.toml`` (matching ADR 014's
   text) or does ADR 014 get corrected to say app-env only?
