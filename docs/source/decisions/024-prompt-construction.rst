:orphan:

Prompt construction: per-model prompts and an environment block
===============================================================

.. adr::
   :id: 024
   :status: Accepted
   :date: 2026-09-21
   :tags: prompts, agents, providers, licensing

.. note::
   Accepted and implemented 2026-09-21. Answers T1/T12 of the
   ``code_review.md`` "rival opencode" list. Decides (a) that the system
   prompt gains a per-model provider file and a per-call environment
   block, (b) that we vendor opencode's provider files under MIT with
   attribution, adapting the identity, and (c) that the parsed-but-unused
   agent fields (``temperature``, ``max_turns``) are either wired or
   removed (T3).

   **Implemented:** ``Prompt.family/1`` + ``framework/1`` select
   ``priv/coding-agent/prompts/{default,claude}.txt`` by model id;
   ``Prompt.environment/2`` builds the per-call block;
   ``Prompt.with_environment/3`` appends it on the wire only; a model
   switch recomposes ``base_prompt`` and the system message
   (``apply_model/2`` + ``recompose_prompt/1``); ``temperature`` rides
   the request opts (``wire_request/1``, a new testable seam);
   ``prompt_override`` is a ``State`` field so a switch and a resume both
   keep a caller's custom prompt. ``max_turns`` remains open (question 1).
   Attribution in ``LICENSES/MIT.txt`` and ``THIRD_PARTY.md``.

Context
-------

Today every model gets **one** framework prompt, five lines long
(``Core.Session.Prompt.@framework_prompt``). It names no working
directory, no platform, no date, and no model. The reference tools do
not work this way: opencode ships several prompt files and selects one
by model ID, and generates a per-call environment block.

Reading opencode's source (``packages/opencode/src/session/system.ts``,
MIT, 2026-09-21) settled what the provider-dependent part actually is.
It is **not** nine unrelated prompts: the files are ~90% the same
document, reordered and re-trimmed per model family. The same worked
examples, the same "do not add comments" rule, the same tool-usage
policy appear in each. The differences are calibration:

- ``anthropic.txt`` opens with a persona line, adds a *Professional
  objectivity* section (truth over validating the user), and insists on
  ``TodoWrite``; it **loosens** the brevity rule to "short and concise".
- ``default.txt`` is the strictest: the hard "fewer than 4 lines / one
  word answers are best" rule with five worked examples. It reads as the
  tuning for smaller, less reliable models.

The lesson is that **the prompt is a per-model tuning surface**, not a
one-time document. A local Ollama model receiving the same five lines as
a frontier model is the analogue of shipping ``default.txt`` to Claude.

Correction to the secondary source: the circulating summary (rmk40
gist) claims the fallback is ``qwen.txt`` and the ``beast.txt`` branch
covers only "GPT/o1/o3". The source shows **nine** branches and **no
``qwen.txt``** — the fallback is ``default.txt``, and there are separate
``gpt.txt`` / ``gpt-astra.txt`` (gpt-6) / ``codex.txt`` branches, plus
``meta.txt`` (muse), ``trinity.txt``, and ``kimi.txt``.

### The environment block

``SystemPrompt.environment`` regenerates, per call:

.. code-block:: text

   You are powered by the model named <id>. The exact model ID is <provider>/<id>
   Here is some useful information about the environment you are running in:
   <env>
     Working directory: <dir>
     Workspace root folder: <worktree>
     Is directory a git repo: yes|no
     Platform: <os>
     Today's date: <date>
   </env>

This is cheap, mechanical, and genuinely useful — the model cannot infer
the date or that it is in a git repo, and a wrong assumption there costs
a tool round.

Decision
--------

**1. The environment block is per-call state, not part of the persisted
prompt.** Our ``base_prompt`` is composed once and persisted in the
session (``session.ex:381``); a date or cwd baked into it goes stale and
defeats prompt caching. The block is therefore appended at REQUEST time,
not stored. ``Prompt.base/2`` stays the stable, cacheable prefix;
``Prompt.environment/1`` produces the volatile suffix.

**2. Provider-specific prompts, keyed on the model ID we already
parse.** ``Request.build/2`` already splits ``provider:model-id``, so the
seam exists: a ``Prompt.for_model/1`` selector maps a model id to a
prompt file, defaulting to a strict base. We start with **two**: a
strict default (example-heavy, tuned for local models) and a Claude
variant. Nine files would be premature while our only dogfooded models
are Ollama and Ollama Cloud; the selector makes adding one a data change.

**3. We vendor opencode's provider files under MIT, with attribution,
and adapt them.** See the licensing section below — this is a deliberate
choice, not an oversight. The vendored text is the *calibration* we do
not yet have data to write ourselves; the identity lines are rewritten.

**4. ``temperature`` and ``max_turns`` are wired or removed (T3).** They
are parsed into ``Core.Agent`` and used nowhere (verified); a documented
field that does nothing is a lie in the docs. ``temperature`` rides the
request opts (``Request.call_opts/2``); ``max_turns`` becomes a real
round budget with a summarizing stop, or it leaves the honoured-fields
list in ADR 017.

Licensing: vendoring MIT into an MPL project
--------------------------------------------

The project will be **MPL-2.0** (owner's choice; not yet committed as a
``LICENSE`` file). The provider files are needed now, so the question is
how to take MIT text into an MPL project honestly.

**MIT permits it.** MIT grants use, modification, sublicensing and
commercial use; its only condition is that the copyright and permission
notice appear in "all copies or substantial portions of the Software".

**MPL permits the combination.** MPL-2.0 is file-level copyleft and
explicitly allows a "Larger Work" that combines MPL files with
differently-licensed files (MPL §3.3). Permissive code may be
incorporated provided its notice is retained.

**The rule we adopt:** vendored opencode prompt files keep their **MIT
license and copyright notice**; they are **not** relicensed as MPL.
Every other file we write is MPL. This is the standard, REUSE-compliant
shape (separate license metadata per file).

Concretely:

- a ``LICENSES/MIT.txt`` holding opencode's notice, and eventually
  ``LICENSES/MPL-2.0.txt`` for our own files;
- each vendored file carries an SPDX header and a provenance line
  (source URL + commit), so attribution survives copying;
- a ``NOTICE`` / ``THIRD_PARTY`` entry naming opencode as the source;
- REUSE compliance (``REUSE.toml`` or per-file SPDX) when the owner
  commits to a license — this ADR only fixes the *vendoring* rule.

**Identity must be rewritten, not just attributed.** The files open with
"You are opencode…" and reference opencode's docs and GitHub issues.
Vendoring them verbatim would instruct our agent to impersonate opencode
and route users to another project's tracker. Attribution licenses the
borrowing; it does not license impersonation. Every identity and URL
line is replaced with ours; the calibration prose is what we keep.

Consequences
------------

- The agent gains a working directory, platform, date and model identity
  it currently lacks, and a prompt calibrated to its model rather than
  one tuned for a frontier model.
- ``base_prompt`` stays prompt-cacheable; only the suffix changes per
  call.
- The provider-file set is a maintenance surface that drifts (opencode
  has nine). Keeping it at two, behind a selector, bounds that cost.
- Attribution is structural (SPDX + ``LICENSES/`` + ``NOTICE``), so it
  cannot be lost by a later refactor.
- MPL vs MIT is a project-wide decision this ADR only *relies on*; a
  future ADR (or a ``LICENSE`` commit) fixes the project license itself.

Open questions
--------------

1. Does ``max_turns`` become a real budget (a summarizing stop, like
   opencode's ``max-steps.txt``) or is it removed?
2. Should the plan fragment move from the system prompt to the last user
   message, as opencode does? ADR 017 records the fork; this ADR does
   not decide it.
3. Is a second prompt variant enough to justify the selector now, or is
   the selector speculative until a second model is dogfooded?
