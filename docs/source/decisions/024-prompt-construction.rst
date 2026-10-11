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
   ``TODO.md`` "rival opencode" list. Decides (a) that the system
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
   keep a caller's custom prompt. ``max_turns`` became ADR 025 (a real
   per-agent budget with a summarizing wrap-up); question 1 below records
   that answer. Attribution in ``LICENSES/MIT.txt`` and
   ``THIRD_PARTY.md``.

Context
-------

Today every model gets **one** framework prompt, five lines long
(``Core.Session.Prompt.@framework_prompt``). It names no working
directory, no platform, no date, and no model. The reference tools do
not work this way: opencode ships several prompt files and selects one
by model ID, and generates a per-call environment block.

Reading opencode's source (then
``packages/opencode/src/session/system.ts``; MIT; the file set has since
moved and changed size — see the amendment below) settled what the
provider-dependent part actually is.
It is **not** one unrelated prompt per model: the files are ~90% the same
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

Correction to the secondary source: a circulating summary (rmk40 gist)
claimed the fallback is ``qwen.txt`` and that a ``beast.txt`` branch
covered only "GPT/o1/o3". Two parts of that were wrong and one was right:
there is no ``qwen.txt``, and the branches were separate files rather than
a GPT-only branch — but a ``beast.txt`` did exist, and the count in this
paragraph ("nine") was a snapshot that no longer holds (review N79; see
the amendment on the source). What matters for the decision is only the
shape: a set of per-model variants over one shared document.

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

.. note::
   **Amendment 2026-10-01 — the block names the harness.** The field list
   quoted above is opencode's, not ours. Ours is the same minus
   ``Workspace root folder`` (we have no separate worktree root) plus one
   line: ``Harness: CodingAgent (agentic coding assistant, unreleased)``,
   emitted from ``Prompt.harness/0``.

   The reason is specific to this project: the repository is **both** the
   harness and the product, so an agent reviewing the code it is running in
   otherwise has to infer that the software it is inside is the software it
   is reading. The other fields describe the *machine*; this one describes
   the *program*.

   The product has no name of its own yet — the README says CodingAgent,
   the app is ``:coding_agent``, and ``mix.exs`` carries no product name.
   When it gets one, ``Prompt.harness/0`` is the single place to change it.

.. note::
   **Amendment 2026-10-04 — the block names the session (harness feedback
   P2).** The block gained four rows for facts the model cannot infer from
   the tree, each one a tool round the agent was otherwise spending:

   * ``Git:`` — the branch, and whether the scope root is a linked
     **worktree**. Read from the filesystem, not from ``git``: a linked
     worktree's ``.git`` is a *file* of the form
     ``gitdir: <main>/.git/worktrees/<name>``, whose ``HEAD`` names the
     branch. Two file reads replace ``git worktree list``.
   * ``Agent:`` — the definition's **name** (``plan``, ``build``, a
     subagent). The name is the mode, because the definition carries the
     read-only/write split; the block does *not* re-derive the capability.
     The capability block (ADR 024 follow-up) already states the resulting
     tools and shell root authoritatively, so repeating that here would be
     the same fact twice — and could drift the moment the two are computed
     differently.
   * ``Store:`` — the active session database. Checkpoint refs are
     store-namespaced, so "did this file ever get committed" is only
     answerable against the right store.

   ``environment/3`` and ``with_environment/4`` take these as an **opts**
   keyword (``:agent``, ``:store``); ``Session`` fills them from the state
   the request is built from. A caller that passes none (a pure
   string-level test) gets exactly the old block, so the extension is
   additive and ``Prompt`` stays a pure prompt function.

   Why the environment block and not the capability block: these are
   *session identity*, which is what ``<env>`` is for; the capability block
   states what the session may *do*. Both ride every request.

.. note::
   **Amendment 2026-10-11 — the source moved, and "nine" is stale (review
   N79).** The Context above quotes opencode at
   ``packages/opencode/src/session/system.ts`` (MIT, 2026-09-21) and says
   the source shows **nine** branches. A re-read (2026-10-11, opencode
   ``7b3d4ce3a7``) found neither the path nor the count:

   * The prompt files are **not** under ``packages/opencode`` any more.
     They live at ``packages/core/src/plugin/system-prompt/*.txt`` — **six**
     files (``anthropic``, ``gpt``, ``gpt-astra``, ``kimi``, ``meta``,
     ``trinity``) plus a runner prompt at
     ``packages/core/src/session/runner/prompt/system.txt``. The directory
     moved with ``720f062cd0`` ("select system prompts through plugins")
     and the old package was removed in ``44b6938b2a``.
   * The file **count has never been stable.** The old directory
     (``packages/opencode/src/session/prompt/``) held one file at its
     earliest revision and **fifteen** at its highest; at its last revision
     (``44b6938b2a^``, 2026-07-20) it held fourteen. So "nine" was a
     snapshot of *some* commit, and any such number is stale on arrival.

   Neither the count nor the path is load-bearing for the decision — what
   we take is *structure and calibration*, and that is unaffected. The
   consequences are that (a) ``THIRD_PARTY.md`` no longer states a count,
   and (b) a future re-read should date and SHA-pin what it read, as this
   note does.

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

- The agent gains a working directory, platform, date, model identity and
  the name of the harness it runs in, which it currently lacks, and a
  prompt calibrated to its model rather than one tuned for a frontier
  model.
- ``base_prompt`` stays prompt-cacheable; only the suffix changes per
  call.
- The provider-file set is a maintenance surface that drifts (opencode's
  has changed size repeatedly; see the amendment on the source). Keeping
  it at two, behind a selector, bounds that cost.
- Attribution is structural (SPDX + ``LICENSES/`` + ``NOTICE``), so it
  cannot be lost by a later refactor.
- MPL vs MIT is a project-wide decision this ADR only *relies on*; a
  future ADR (or a ``LICENSE`` commit) fixes the project license itself.

Open questions
--------------

1. Does ``max_turns`` become a real budget (a summarizing stop, like
   opencode's ``max-steps.txt``) or is it removed? **Answered by ADR
   025: it becomes a real per-agent budget whose trip results in a
   summarizing wrap-up, not a failed turn.**
2. Should the plan fragment move from the system prompt to the last user
   message, as opencode does? ADR 017 records the fork; this ADR does
   not decide it.
3. Is a second prompt variant enough to justify the selector now, or is
   the selector speculative until a second model is dogfooded?
4. **How much of the calibration did we actually take?** Reading the
   source above, the files look ~90% identical *to each other*. The
   overlap between **our** file and any upstream one has not been measured
   line-by-line. What is checkable today: every structural feature named
   as "ours" in ``THIRD_PARTY.md`` (the identity rewrite, the tool-name
   mapping, the harness/``<env>`` block, the ``Context budget`` section)
   is absent from upstream, and the retained material is at the
   rule level — the same *instructions* expressed in our words. That is
   the shape of an adaptation; whether "~90%" is the right number for it
   is not established by this ADR and should not be quoted as if it were.
