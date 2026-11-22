.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

A subagent's model is a machine-local choice, not an agent's
============================================================

.. adr::
   :id: 042
   :status: Accepted
   :date: 2026-09-30
   :tags: agents, subagents, models, config

.. note::
   Accepted 2026-09-30; implementation landed with this record. Adds one
   layered knob (``subagent_model``) and makes the child-model resolution
   a single function, so the child session and its UI event cannot
   disagree. Decided together with the ADR 017 amendment that ships the
   ``explore`` subagent.

Context
-------

A subagent does *mechanical* work — searching the tree, reading many
files, collecting references — and returns a short answer. That is a
different job from the primary agent's, which reasons about a task and
owns its outcome. Mechanical work tolerates a cheaper or faster model,
and on a metered provider it is often the bulk of the tokens, so running
it on the primary's model is wasteful.

The obvious place to say "use a cheaper model" looks like the agent
definition's ``model`` field. It is the wrong place, and shipping
``explore`` made that concrete: a model id is an assertion about **this
machine** — which providers exist, which models are cheap, whether a
local model is available at all. A definition shipped in the repository
cannot know any of that. Pinning a model in shipped data would either
break on a user without that provider or force us to guess on the user's
behalf. The choice belongs in configuration, next to the other
machine-local knobs (``subagent_concurrency``, the compaction budgets).

At the same time, two sources already resolved the child model — the
child session (``Subagent.start_child/3``) and the parent event that
names the model in the subagent's tab (``child_model/2``) — which is the
kind of duplication that lets the tab display one model while the child
runs another.

Decision
--------

**1. One new layered knob: ``subagent_model``.** Resolution mirrors
``subagent_concurrency/1``: the layered ``config.toml`` key (project over
global), then the ``:subagent_model`` app-env override, then **``nil``**.
``nil`` means "inherit the parent's effective model" — so the default
behavior is exactly today's: *the same model as the main agent*. A blank
value is treated as unset.

**2. Three-level precedence, strongest first:**

1. the agent definition's pinned ``model`` (a per-agent assertion — the
   one place a definition may still pin, and only a user file should);
2. ``config.toml subagent_model`` (this machine's cheap-worker default);
3. the parent's ``State.effective_model/1``.

Step 1 keeps ADR 017 decision 5 intact: the definition still wins over
the session. The knob is inserted as the *fallback* the decision never
named — which the shipped ``explore`` uses by pinning nothing.

**3. One resolver, ``Subagent.child_model/2``.** Both the value handed to
``start_child/3`` and the model announced in ``{:subagent_started, ...}``
come from it, so the tab can never name a different model than the child
runs. It reads the config at spawn time (fresh snapshot of the parent's
scope root), not from a cached state field — so editing ``config.toml``
and delegating again takes effect without a session restart, the same way
``subagent_concurrency`` is read per round.

Consequences
------------

- Default behavior is unchanged: with no ``subagent_model`` configured, a
  subagent inherits the primary's model.
- A user who sets ``subagent_model = "ollama:qwen2.5:3b"`` puts every
  subagent on that model, except any definition that pins its own.
- The shipped ``explore`` is model-less by design: it is the reason the
  knob exists, and it must not presume the user's providers.
- A cheaper model is only safe for *tolerant* jobs, where the search is
  the work and the judgement is thin (locate, collect). It is **not** safe
  where the judgement *is* the product (verify a change against a spec);
  that is why a per-agent pin still outranks the global knob — a stronger
  ``review``-style agent pins up while the global knob stays cheap.

Open questions
--------------

1. **Per-subagent-kind override.** The knob is global to all subagents; a
   per-definition config table (``[subagents.explore] model = ...``)
   would let one knob address one kind without editing agent files. Not
   needed yet — the definition pin covers the exception.
2. **Cost visibility.** With a split model, a turn's token cost mixes two
   prices. ``Usage`` records what the provider reports, but the sidebar
   attributes it to the session; attributing child tokens to the child's
   model is a separate display question.
3. **Reasoning effort for subagents.** ``reasoning_effort`` is one global
   knob (ADR 029); a subagent may want less. Same shape as this decision
   if it proves needed.
