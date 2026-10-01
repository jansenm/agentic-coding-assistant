Configuration reference
=======================

Every configuration file, key, default, and layer, in one place. For the
*why* behind the layering see :doc:`../decisions/014-user-config`; for the
narrative map of sources see
:doc:`../explanation/configuration-landscape`.

.. note::

   The tables below are checked against the code by
   ``test/coding_agent/docs/config_reference_test.exs``. A configuration
   key that is read but not documented here — or documented but no longer
   read — fails that test.

File locations
--------------

.. list-table::
   :header-rows: 1
   :widths: 34 22 44

   * - Path
     - Scope
     - Contents
   * - ``priv/coding-agent/config.toml``
     - shipped
     - Layer 0 defaults (provider entries, sandbox, budgets). Versioned
       with the app; do not edit.
   * - ``~/.config/coding-agent/config.toml``
     - user
     - Model, providers, runtime knobs, stores, sandbox.
   * - ``<scope_root>/.coding-agent/config.toml``
     - project
     - Same shape as the user file; overlays it. ``rw`` mounts are ignored
       here (non-elevation).
   * - ``~/.config/coding-agent/ui.toml``
     - user
     - Keymap overrides.
   * - ``~/.config/coding-agent/permissions.toml``
     - user
     - Tool enablement and per-path decisions.
   * - ``<scope_root>/.coding-agent/permissions.toml``
     - project
     - Same shape; may only tighten the user layer.
   * - ``~/.local/share/coding-agent/auth.toml``
     - user only
     - API keys (``[<provider>] api_key``). Never read from a project.

Layer order, weakest to strongest: shipped ``priv`` defaults, global
``~/.config/coding-agent``, project ``<scope_root>/.coding-agent``,
environment / CLI. Missing files are fine; malformed TOML is a hard error
naming the file (ADR 014).

``config.toml`` keys
--------------------

.. list-table::
   :header-rows: 1
   :widths: 28 16 18 38

   * - Key
     - Type
     - Default
     - Meaning
   * - ``model``
     - string
     - *none*
     - Default model as ``provider:model``. No default is baked into the
       code; a missing value is a hard error naming this file. `AGENT_MODEL`
       overrides it.
   * - ``[providers.<name>]``
     - table
     - shipped
     - The ``providers`` table: per-provider connection info. ``base_url``
       (string), ``provider`` (an OpenAI-compatible req_llm module to ride),
       ``backend`` (``ollama`` sets the compatible backend), ``discover``
       (``openai`` or ``ollama``, the model-list source). Catalog providers
       need no entry.
   * - ``max_tool_rounds``
     - integer
     - ``100``
     - Per-turn tool-round budget (ADR 025). An agent's ``maxTurns``
       overrides it.
   * - ``subagent_concurrency``
     - integer
     - ``3``
     - Maximum ``task`` subagents running at once in one round (ADR 018).
   * - ``subagent_model``
     - string
     - *unset*
     - Model a ``task`` subagent runs on (ADR 042), e.g.
       ``"ollama:qwen2.5:3b"``. Unset means the subagent inherits the
       primary's model. A definition's pinned ``model`` still wins over
       this (ADR 017 decision 5: definition > this key > parent).
   * - ``reasoning_effort``
     - string
     - *unset*
     - One of ``none``, ``minimal``, ``low``, ``medium``, ``high``,
       ``xhigh``, ``max``, ``default``. Unset means the provider default.
       Any other value is a startup error (ADR 029).
   * - ``provider_retries``
     - integer
     - ``3``
     - How many times a provider timeout is retried before the turn fails
       (ADR 033). ``0`` disables the retry.
   * - ``provider_retry_delay_ms``
     - integer
     - ``5000``
     - Milliseconds to wait between provider-timeout retries (ADR 033).
   * - ``provider_receive_timeout_ms``
     - integer
     - ``120000``
     - Provider transport inactivity timeout for a call (ADR 041). On a
       streaming call this is the inter-chunk idle budget: the socket may
       be silent this long before the call fails. Without it the turn
       inherited req_llm's 30s default, which a reasoning model's slow
       first token can exceed. A non-positive value falls through to the
       default.
   * - ``checkpoint_depth``
     - integer
     - ``1``
     - How many file checkpoints a session keeps for ``/undo`` (ADR 036).
       ``0`` disables checkpoints.
   * - ``context_window``
     - integer
     - *catalog*
     - The model's context window in tokens (ADR 037), for the two
       compaction limits. Resolution: this key, then the catalog window,
       then the 500000 fallback. Set it for a cloud model absent from the
       catalog. When the fallback is used (the catalog does not know the
       model), the session emits one note and the sidebar marks ``soft at``
       as ``(assumed)`` — the 500000-token guess can make compaction fire
       later than a small model can hold.
   * - ``compaction_soft_ratio``
     - number
     - ``0.5``
     - Fraction of the window at which an IDLE session compacts (ADR 037).
   * - ``compaction_hard_reserve_tokens``
     - integer
     - ``64000``
     - Tokens held back under the window for the hard (pre-call)
       compaction limit (ADR 037): ``hard = window - reserve``.
   * - ``store``
     - string
     - *unset*
     - Default store, as a name or a path. See ``[stores]``.
   * - ``[stores]``
     - table
     - *empty*
     - Named stores (the ``stores`` table): ``name = "<path>"``. Selected by
       ``--store``, then `AGENT_STORE`, then ``store =``, then the default
       ``~/.local/state/coding_agent/store.db``.
   * - ``[sandbox]``
     - table
     - shipped
     - Mount schema (ADR 015): ``rw``, ``ro``, ``hide`` are lists of host
       paths. ``rw`` is honored only from the shipped and user layers; a
       project may not widen the sandbox.

Runtime knobs not read from ``config.toml``
-------------------------------------------

These have no layered file key; they resolve from the application
environment (``config/config.exs`` or ``Application.put_env/3``) over the
built-in default. They are listed here so the surface is complete.

.. list-table::
   :header-rows: 1
   :widths: 40 18 42

   * - App-env key
     - Default
     - Meaning
   * - ``:compaction_soft_ratio``
     - ``0.5``
     - Default soft compaction ratio (ADR 037) when not set in ``config.toml``.
   * - ``:compaction_hard_reserve_tokens``
     - ``64000``
     - Default hard-limit reserve (ADR 037) when not set in ``config.toml``.
   * - ``:compaction_wall_clock_ms``
     - ``300000``
     - Hard wall-clock bound on the summarize call.
   * - ``:compaction_inactivity_ms``
     - ``120000``
     - Inactivity bound inside the summarize call.
   * - ``:context_window_tokens``
     - ``500000``
     - Fallback context window (ADR 037) when neither ``config.toml`` nor
       the catalog provides one.
   * - ``:store_path``
     - *unset*
     - Hard store-path override (the test seam and what ``--store`` sets).

``ui.toml`` keys
----------------

.. list-table::
   :header-rows: 1
   :widths: 28 20 52

   * - Key
     - Type
     - Meaning
   * - ``[keys]``
     - table
     - Keymap overrides: action name to a key chord. Merged over the
       built-in keymap (ADR 011).

``permissions.toml`` keys
-------------------------

.. list-table::
   :header-rows: 1
   :widths: 28 20 52

   * - Key
     - Type
     - Meaning
   * - ``enabled``
     - array of strings
     - Tool allow-list. Narrowed by an agent definition's ``tools``;
       never widened.
   * - ``[<tool>]``
     - table
     - Per-path glob decisions: ``"<pattern>" = "allow" | "ask" | "deny"``.
       Most specific match wins; ties resolve to the more restrictive
       decision (ADR 010).
   * - ``shell``
     - string
     - ``"read_only"`` (besides the three decisions) binds the scope root
       read-only for ``shell``.

``auth.toml`` keys
------------------

.. list-table::
   :header-rows: 1
   :widths: 28 20 52

   * - Key
     - Type
     - Meaning
   * - ``[<provider>] api_key``
     - string
     - API key for the provider. Resolved after the environment variable
       ``<PROVIDER>_API_KEY`` (ADR 014).

Agent-definition frontmatter
----------------------------

Agent files are Markdown with YAML frontmatter, loaded from the shipped,
user (``~/.config/coding-agent/agents/``) and project
(``.agents/agents/``) layers (ADR 017).

.. list-table::
   :header-rows: 1
   :widths: 24 18 58

   * - Field
     - Type
     - Meaning
   * - ``description``
     - string
     - Required. The delegation hint the model sees.
   * - ``name``
     - string
     - Agent name. Defaults to the filename without its extension.
   * - ``mode``
     - enum
     - ``primary``, ``subagent``, ``all`` (default), or ``internal``.
       ``primary``/``all`` are selectable by the human; ``subagent`` is
       only a ``task`` target; ``internal`` is driven by the runtime (the
       ``compaction`` agent) and appears in no picker (ADRs 029, 044).
       With ``hidden``, decides whether the human may select it (ADR 029).
   * - ``model``
     - string
     - Pinned model for this agent's turns (ADR 017). For a ``subagent``,
       precedence is: this field, then ``subagent_model`` (ADR 042), then
       the parent's model. For the ``compaction`` agent (ADR 044), this
       field then the session model. A pinned compaction model must be
       able to hold the summarized span (~75k tokens worst case).
   * - ``tools``
     - array
     - Allow-list of tools; intersects the policy's enabled set.
   * - ``disallowedTools``
     - array
     - Deny-list; aliases ``disallowed_tools``.
   * - ``permission``
     - table
     - Same shape as a policy layer; restrictive only.
   * - ``temperature``
     - number
     - Sampling temperature for this agent's requests.
   * - ``maxTurns``
     - integer
     - Per-turn tool-round budget; aliases ``max_turns``.
   * - ``hidden``
     - boolean
     - ``true`` keeps the definition out of the human selection surface.

Environment variables
---------------------

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Variable
     - Meaning
   * - ``AGENT_MODEL``
     - Override the configured default model for this run.
   * - ``AGENT_STORE``
     - Store name or path; overrides ``store =`` but not ``--store``.
   * - ``<PROVIDER>_API_KEY``
     - API key (uppercase provider name, e.g. ``OLLAMA_API_KEY``);
       strongest credential source.
   * - ``XDG_CONFIG_HOME``
     - Base for ``~/.config``, hence the global config directory.
   * - ``XDG_DATA_HOME``
     - Base for ``~/.local/share``, hence ``auth.toml``.
   * - ``XDG_STATE_HOME``
     - Base for ``~/.local/state``, hence the default store.
   * - ``HOME``
     - Fallback base when the ``XDG_*`` variables are unset.
