defmodule CodingAgent.Core.Config do
  @moduledoc """
  The ONE configuration boundary (ADR 008).

  Before this module, merged TOML, permissions, mounts, provider tables,
  runtime knobs and credentials were each read from wherever they were
  needed: ten `Application.get_env` sites and eight `System.get_env`
  sites across core, UI and CLI, with `Session.init` reading the same
  config three times through three different paths and defaults copied
  between `config/config.exs` and module attributes.

  Two kinds of configuration live here, deliberately distinct:

    * **File configuration** — the layered TOML (ADR 014). Read once by
      `snapshot/1`, which returns the merged config/ui, the policy, the
      sandbox mounts, the `[providers.*]` table and the agent
      definitions as plain data. Callers thread the snapshot instead of
      re-reading files.
    * **Runtime knobs** — application-env values that are compile-time
      defaults or test seams (compaction budgets, tool-round guard,
      state dir, sandbox choice). These have small typed accessors; each
      key has exactly one default, defined here rather than duplicated
      in `config/config.exs` and a module attribute.
  """

  alias CodingAgent.Core.Agent
  alias CodingAgent.Core.Sandbox.Mounts
  alias CodingAgent.Core.UserConfig

  # -- Runtime knob defaults (the single source; config/config.exs no
  # longer repeats these). ------------------------------------------------

  @default_max_tool_rounds 100
  @default_subagent_concurrency 3
  @default_context_window_tokens 500_000
  @default_compaction_soft_ratio 0.5
  @default_compaction_hard_reserve_tokens 64_000
  # The hard limit is at most this fraction of the window, so a window
  # smaller than the absolute reserve does not collapse it (review N1).
  @hard_window_floor_ratio 0.75
  @default_compaction_wall_clock_ms 300_000
  @default_compaction_inactivity_ms 120_000
  @default_compaction_prefill_tokens_per_sec 1_000
  @default_provider_retries 3
  @default_provider_retry_delay_ms 5_000
  @default_provider_receive_timeout_ms 120_000
  @default_checkpoint_depth 1

  # req_llm's canonical reasoning efforts (ADR 029); the accepted
  # config.toml strings, one to one.
  @reasoning_efforts ~w(none minimal low medium high xhigh max default)
  @reasoning_effort_atoms Enum.map(@reasoning_efforts, &String.to_atom/1)

  @typedoc "One typed read of the layered file configuration for a scope."
  @type t :: %__MODULE__{
          root: String.t() | nil,
          config: %{String.t() => term()},
          ui: %{String.t() => term()},
          permissions: CodingAgent.Core.Permissions.t(),
          layers: %{String.t() => [map()]},
          providers: %{String.t() => term()},
          mounts: Mounts.t(),
          agents: {:ok, [Agent.t()]} | {:error, [String.t()]}
        }

  defstruct [:root, :config, :ui, :permissions, :layers, :providers, :mounts, :agents]

  @doc """
  Reads the layered file configuration for `scope_root` (`nil`: globals
  only) exactly once and returns it as a typed snapshot. Every file
  read — config.toml, ui.toml, permissions.toml, agent definitions —
  happens here; callers never re-read.
  """
  @spec snapshot(String.t() | nil) :: t()
  def snapshot(scope_root \\ nil) do
    user = UserConfig.load(scope_root)
    layers = user.layers

    %__MODULE__{
      root: scope_root,
      config: user.config,
      ui: user.ui,
      permissions: user.permissions,
      layers: layers,
      providers: Map.get(user.config, "providers") || %{},
      # `rw` may only come from shipped + global, never the project layer
      # (ADR 015 non-elevation) — hence the per-layer view.
      mounts: Mounts.resolve(Map.get(layers, "config", [])),
      agents: Agent.load(scope_root)
    }
  end

  @doc """
  Loads the agent definitions for a scope (ADR 017) without reading the
  rest of the layered config — for the rare Tab-switch path where only
  the definitions are needed.
  """
  @spec agents(String.t() | nil) :: {:ok, [Agent.t()]} | {:error, [String.t()]}
  def agents(scope_root \\ nil), do: Agent.load(scope_root)

  # -- Model -------------------------------------------------------------------

  @doc """
  The configured model spec: the `AGENT_MODEL` env override first, then
  config.toml `model =` (project over global). `nil` when neither source
  has one — the caller decides (the TUI fails loudly with
  `no_model_message/0`).

  Accepts either a scope root (reads a fresh snapshot) or an existing
  snapshot, so a caller that already read the config does not read it
  again.
  """
  @spec model(String.t() | nil | t()) :: String.t() | nil
  def model, do: model(nil)

  def model(%__MODULE__{} = snapshot),
    do: System.get_env("AGENT_MODEL") || snapshot.config["model"]

  def model(scope_root), do: model(snapshot(scope_root))

  @doc "The human-readable message shown when no model is configured."
  @spec no_model_message() :: String.t()
  def no_model_message do
    "no model configured. Set model = \"provider:model\" in " <>
      UserConfig.global_dir() <>
      "/config.toml (or a project .coding-agent/config.toml), " <>
      "or override per run with AGENT_MODEL"
  end

  # -- Runtime knobs -----------------------------------------------------------

  @doc """
  Per-turn tool-round budget (ADR 025). The trip no longer fails the turn:
  it ends with a summarizing wrap-up (`Session.gate_tools/2`).

  Resolution, strongest first: an agent definition's ``max_turns`` (applied
  in `State.tool_budget/1`), the layered ``max_tool_rounds`` in
  ``config.toml`` (project over global), the app-env override, then the
  built-in default. Accepts a scope root or an already-read snapshot so a
  caller that holds one does not re-read.
  """
  @spec max_tool_rounds(String.t() | nil | t()) :: pos_integer()
  def max_tool_rounds, do: max_tool_rounds(nil)

  def max_tool_rounds(%__MODULE__{} = snapshot),
    do: configured_rounds(snapshot) || app(:max_tool_rounds, @default_max_tool_rounds)

  def max_tool_rounds(scope_root), do: max_tool_rounds(snapshot(scope_root))

  defp configured_rounds(%__MODULE__{config: config}) do
    case config["max_tool_rounds"] do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc """
  How many `task` subagents may run at once in one round (ADR 018).

  A round's `task` calls run concurrently, capped here so a burst does not
  stampede the provider (the default 3 matches Ollama's parallel limit;
  raise it for a provider that allows more). Resolution, strongest first:
  the layered ``subagent_concurrency`` in ``config.toml`` (project over
  global), the app-env override, then the built-in default. Accepts a
  scope root or an already-read snapshot.
  """
  @spec subagent_concurrency(String.t() | nil | t()) :: pos_integer()
  def subagent_concurrency, do: subagent_concurrency(nil)

  def subagent_concurrency(%__MODULE__{} = snapshot),
    do:
      configured_concurrency(snapshot) ||
        app(:subagent_concurrency, @default_subagent_concurrency)

  def subagent_concurrency(scope_root), do: subagent_concurrency(snapshot(scope_root))

  defp configured_concurrency(%__MODULE__{config: config}) do
    case config["subagent_concurrency"] do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc """
  The model a `task` subagent runs on (ADR 042), or `nil` to inherit the
  parent's effective model.

  A subagent that explores the code, hunts references or summarises a
  large area does mechanical work with a thin judgement, so it is often
  worth running it on a cheaper or faster model than the primary. That
  is a statement about *this machine's* providers, so it belongs in
  configuration, not in a shipped agent file — an agent definition cannot
  know which models a user has. Default: `nil` (the primary's model).

  Resolution, strongest first: the layered ``subagent_model`` in
  ``config.toml`` (project over global), then the ``:subagent_model``
  app-env override. An agent definition's pinned ``model`` still wins
  over this (ADR 017 decision 5: definition > config > parent). Accepts a
  scope root or an already-read snapshot.
  """
  @spec subagent_model(String.t() | nil | t()) :: String.t() | nil
  def subagent_model, do: subagent_model(nil)

  def subagent_model(%__MODULE__{} = snapshot),
    do: configured_string(snapshot, "subagent_model") || app(:subagent_model, nil)

  def subagent_model(scope_root), do: subagent_model(snapshot(scope_root))

  defp configured_string(%__MODULE__{config: config}, key) do
    case config[key] do
      s when is_binary(s) -> if String.trim(s) == "", do: nil, else: s
      _ -> nil
    end
  end

  @doc """
  Soft compaction ratio of the model window (ADR 037): the fraction at
  which an IDLE session summarizes down. Resolution mirrors the other
  runtime knobs: the layered ``compaction_soft_ratio`` in ``config.toml``
  (project over global), the app-env override, then the built-in default
  (0.5).
  """
  @spec compaction_soft_ratio(String.t() | nil | t()) :: float()
  def compaction_soft_ratio, do: compaction_soft_ratio(nil)

  def compaction_soft_ratio(%__MODULE__{} = snapshot),
    do:
      configured_ratio(snapshot, "compaction_soft_ratio") ||
        app(:compaction_soft_ratio, @default_compaction_soft_ratio)

  def compaction_soft_ratio(scope_root), do: compaction_soft_ratio(snapshot(scope_root))

  @doc """
  Absolute reserve held back under the model window for the HARD limit
  (ADR 037), in tokens: the hard limit is ``window - reserve``, so one
  maximum tool result cannot overflow the window mid-turn. Resolution
  mirrors the other runtime knobs; default 64_000 (≈ one 256 KiB tool
  result plus response headroom).
  """
  @spec compaction_hard_reserve_tokens(String.t() | nil | t()) :: pos_integer()
  def compaction_hard_reserve_tokens, do: compaction_hard_reserve_tokens(nil)

  def compaction_hard_reserve_tokens(%__MODULE__{} = snapshot),
    do:
      configured_count(snapshot, "compaction_hard_reserve_tokens") ||
        app(:compaction_hard_reserve_tokens, @default_compaction_hard_reserve_tokens)

  def compaction_hard_reserve_tokens(scope_root),
    do: compaction_hard_reserve_tokens(snapshot(scope_root))

  @doc """
  An ABSOLUTE soft limit in tokens (ADR 037, amendment 2026-10-22), or
  `nil` when unset.

  The ratio keys above describe what the model can HOLD; a per-token
  price makes what a request may COST a separate bound the user owns.
  `compaction_soft_ratio` cannot express it: 0.15 is 157k on a 1M window
  and 19k on a 128k one, so the same spend ceiling would mean different
  things per model. This key is the number itself.

  Composed by `min` with the window-derived limit (`compaction_limits/2`):
  a configured ceiling LOWERS a limit, never raises it past what the
  window can hold.
  """
  @spec compaction_soft_tokens(String.t() | nil | t()) :: pos_integer() | nil
  def compaction_soft_tokens, do: compaction_soft_tokens(nil)

  def compaction_soft_tokens(%__MODULE__{} = snapshot),
    do: configured_positive_count(snapshot, "compaction_soft_tokens")

  def compaction_soft_tokens(scope_root), do: compaction_soft_tokens(snapshot(scope_root))

  @doc """
  An ABSOLUTE hard limit in tokens (ADR 037, amendment 2026-10-22), or
  `nil` when unset — the pre-call ceiling: no request is sent past it.

  This is the key that bounds the cost of a long turn, because the hard
  pass runs pre-call, busy or not; the soft key only decides when an
  IDLE session summarizes. See `compaction_soft_tokens/1` for why the
  ratio cannot express it, and for the `min` composition.
  """
  @spec compaction_hard_tokens(String.t() | nil | t()) :: pos_integer() | nil
  def compaction_hard_tokens, do: compaction_hard_tokens(nil)

  def compaction_hard_tokens(%__MODULE__{} = snapshot),
    do: configured_positive_count(snapshot, "compaction_hard_tokens")

  def compaction_hard_tokens(scope_root), do: compaction_hard_tokens(snapshot(scope_root))

  # A positive float (or integer) ratio in the layered config, else nil.
  defp configured_ratio(%__MODULE__{config: config}, key) do
    case config[key] do
      n when is_number(n) and n > 0 -> n * 1.0
      _ -> nil
    end
  end

  @doc """
  Hard wall-clock bound on the summarize call, in milliseconds.
  """
  @spec compaction_wall_clock_ms() :: pos_integer()
  def compaction_wall_clock_ms,
    do: app(:compaction_wall_clock_ms, @default_compaction_wall_clock_ms)

  @doc "Inactivity bound inside the summarize call, in milliseconds."
  @spec compaction_inactivity_ms() :: pos_integer()
  def compaction_inactivity_ms,
    do: app(:compaction_inactivity_ms, @default_compaction_inactivity_ms)

  @doc """
  The prefill rate the summarize input budget assumes, in tokens per
  second.

  The budget (`Compaction.input_budget/3`) caps the span at
  `inactivity_ms / 1000 × this`, because a prefill that runs longer than
  the inactivity timeout emits no byte while it works and the transport
  kills the call before the first token. It is a PROVIDER property, not a
  policy one: a local model on a fast box may prefills two or three times
  faster, a busy shared endpoint slower. 1 000 is the conservative
  default; raise it only with evidence from a real summarize call.
  """
  @spec compaction_prefill_tokens_per_sec() :: pos_integer()
  def compaction_prefill_tokens_per_sec,
    do: app(:compaction_prefill_tokens_per_sec, @default_compaction_prefill_tokens_per_sec)

  @doc """
  The model's context window in tokens, resolved (ADR 037). Resolution,
  strongest first:

    1. the layered ``context_window`` in ``config.toml`` (project over
       global) — needed for cloud models absent from the catalog;
    2. the catalog window (``Providers.Catalog``, llm_db);
    3. the app-env ``:context_window_tokens`` fallback (default 500k).

  The catalog lookup is NON-BLOCKING: it reads llm_db's already-loaded
  snapshot and returns ``:loading`` while the catalog's background warm
  is still running, so this never queues behind the ~3.7s cold load (the
  startup hang). A ``:loading``/unknown model takes the fallback; the
  session re-resolves when the catalog signals it is ready.

  Accepts a scope root or an already-read snapshot, plus the model spec.
  """
  @spec context_window(String.t() | nil | t(), String.t() | nil) :: pos_integer()
  def context_window(scope_or_snapshot \\ nil, model \\ nil)

  def context_window(%__MODULE__{} = snapshot, model),
    do: context_window_resolved(snapshot, model) |> elem(0)

  def context_window(scope_root, model), do: context_window(snapshot(scope_root), model)

  @typedoc """
  Where the resolved window came from:

    * `:configured` — the layered ``context_window`` key (verified by the user);
    * `{:catalog, tokens}` — llm_db's window for the model (verified);
    * `:loading` — the catalog is still warming; the window is a GUESS the
      session re-resolves on `{:catalog, :updated}` (provisional, expected);
    * `:fallback` — the catalog is loaded but does NOT know the model, so the
      window is the app-env default and is likely wrong for an uncataloged
      cloud model (e.g. `ollama_cloud:*`), which can be far smaller (review:
      the owner's "the compact window is too big to compact").
  """
  @type window_source :: :configured | {:catalog, pos_integer()} | :loading | :fallback

  @doc """
  The model's context window AND its provenance in one read (ADR 037). The
  source lets the caller tell a verified window from the fallback: a
  `:fallback` window on an uncataloged model is a guess worth surfacing,
  `:loading` is provisional and self-heals.
  """
  @spec context_window_resolved(String.t() | nil | t(), String.t() | nil) ::
          {pos_integer(), window_source()}
  def context_window_resolved(scope_or_snapshot \\ nil, model \\ nil)

  def context_window_resolved(%__MODULE__{} = snapshot, model) do
    case configured_window(snapshot) do
      n when is_integer(n) ->
        {n, :configured}

      _ ->
        case CodingAgent.Core.Providers.Catalog.context_window(model) do
          {:ok, tokens} -> {tokens, {:catalog, tokens}}
          :loading -> {@default_context_window_tokens, :loading}
          :unknown -> {@default_context_window_tokens, :fallback}
        end
    end
  end

  def context_window_resolved(scope_root, model),
    do: context_window_resolved(snapshot(scope_root), model)

  @doc """
  Whether the window is pinned by ``config.toml``. When it is, the
  session need not listen for catalog readiness — the configured value
  always wins.
  """
  @spec context_window_configured?(t()) :: boolean()
  def context_window_configured?(%__MODULE__{} = snapshot),
    do: not is_nil(configured_window(snapshot))

  defp configured_window(%__MODULE__{config: config}) do
    case config["context_window"] do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc """
  The resolved compaction window and limits (ADR 037): `{window, soft,
  hard}`. One reader of the ratio/reserve policy, so the session
  resolves it ONCE at init and the sidebar/decision never re-read the
  layered config per frame (the CPU-storm lesson). ``soft`` is clamped
  to ``hard`` so the order never inverts on a small window.

  Two kinds of key compose here, both `min`-ed (amendment 2026-10-22):

    * the RATIO keys describe what the window can HOLD —
      ``soft = round(window * compaction_soft_ratio)`` and
      ``hard = window - compaction_hard_reserve_tokens``;
    * the ABSOLUTE keys describe what a request may COST —
      ``compaction_soft_tokens`` / ``compaction_hard_tokens``. A price
      per token makes cost linear in the context, and a ratio cannot
      express a ceiling: 0.15 is 157k on a 1M window and 19k on a 128k
      one. An absolute key LOWERS a limit and never raises it past what
      the window holds, so configuring one on a large model is a cost
      bound, not a correctness risk.

  The hard limit is ``window - reserve`` but ALSO floored at
  ``window * @hard_window_floor_ratio`` (0.75). Without the floor a
  window smaller than the reserve collapses ``hard`` to 1 — the reserve
  is an absolute 64k, so e.g. ``openai:gpt-3.5-turbo`` (window 16385)
  gave ``hard = max(16385 - 64000, 1) = 1`` and ``soft = 1``: a pre-call
  summarize at 4% utilisation, degrading to a lossy trim if the
  summarize call failed (review N1). The floor keeps the reserve at most
  a quarter of the window for small windows and is continuous with the
  ``window - reserve`` branch at ``window = 4 * reserve``.
  """
  @spec compaction_limits(String.t() | nil | t(), String.t() | nil) ::
          {pos_integer(), pos_integer(), pos_integer()}
  def compaction_limits(scope_or_snapshot \\ nil, model \\ nil)

  def compaction_limits(%__MODULE__{} = snapshot, model) do
    {window, _source} = context_window_resolved(snapshot, model)
    limits_for_window(snapshot, window)
  end

  def compaction_limits(scope_root, model), do: compaction_limits(snapshot(scope_root), model)

  @doc """
  `compaction_limits/2` together with the window's provenance, in one
  catalog read, so the session can resolve the limits AND decide whether
  to surface an unverified fallback window.
  """
  @spec compaction_limits_resolved(String.t() | nil | t(), String.t() | nil) ::
          {{pos_integer(), pos_integer(), pos_integer()}, window_source()}
  def compaction_limits_resolved(scope_or_snapshot \\ nil, model \\ nil)

  def compaction_limits_resolved(%__MODULE__{} = snapshot, model) do
    {window, source} = context_window_resolved(snapshot, model)
    {limits_for_window(snapshot, window), source}
  end

  def compaction_limits_resolved(scope_root, model),
    do: compaction_limits_resolved(snapshot(scope_root), model)

  defp limits_for_window(%__MODULE__{} = snapshot, window) do
    reserve = compaction_hard_reserve_tokens(snapshot)
    floor = round(window * @hard_window_floor_ratio)
    hard = min(max(window - reserve, floor), absolute(snapshot, :hard, window))
    ratio = compaction_soft_ratio(snapshot)
    soft = min(min(round(window * ratio), absolute(snapshot, :soft, window)), hard)
    {window, max(soft, 1), max(hard, 1)}
  end

  # An absolute ceiling from config (`compaction_soft_tokens` /
  # `compaction_hard_tokens`), or the window itself when unset — so `min`
  # leaves the derived limit alone. Clamped to the window: a ceiling
  # ABOVE it would be a no-op dressed as a setting.
  defp absolute(%__MODULE__{} = snapshot, :soft, window) do
    case compaction_soft_tokens(snapshot) do
      nil -> window
      tokens -> min(tokens, window)
    end
  end

  defp absolute(%__MODULE__{} = snapshot, :hard, window) do
    case compaction_hard_tokens(snapshot) do
      nil -> window
      tokens -> min(tokens, window)
    end
  end

  @doc """
  How many times a provider TIMEOUT is retried before the turn fails.

  A transient transport timeout (req_llm's ``%ReqLLM.Error.API.Timeout{}``)
  is not a permanent failure, so the session waits and tries again instead
  of ending the turn. This is the maximum number of RETRIES (``0`` disables
  the retry). Resolution, strongest first: the layered
  ``provider_retries`` in ``config.toml`` (project over global), the
  app-env override, then the built-in default (3).
  """
  @spec provider_retries(String.t() | nil | t()) :: non_neg_integer()
  def provider_retries, do: provider_retries(nil)

  def provider_retries(%__MODULE__{} = snapshot),
    do:
      configured_count(snapshot, "provider_retries") ||
        app(:provider_retries, @default_provider_retries)

  def provider_retries(scope_root), do: provider_retries(snapshot(scope_root))

  @doc """
  How long to wait between provider-timeout retries, in milliseconds.

  Resolution mirrors ``provider_retries/1``: the layered
  ``provider_retry_delay_ms`` in ``config.toml`` (project over global), the
  app-env override, then the built-in default (5000).
  """
  @spec provider_retry_delay_ms(String.t() | nil | t()) :: non_neg_integer()
  def provider_retry_delay_ms, do: provider_retry_delay_ms(nil)

  def provider_retry_delay_ms(%__MODULE__{} = snapshot),
    do:
      configured_count(snapshot, "provider_retry_delay_ms") ||
        app(:provider_retry_delay_ms, @default_provider_retry_delay_ms)

  def provider_retry_delay_ms(scope_root), do: provider_retry_delay_ms(snapshot(scope_root))

  @doc """
  The provider transport INACTIVITY timeout for a call, in milliseconds
  (ADR 041).

  On a streaming call this is the inter-chunk idle budget: the socket may
  be silent for at most this long before the call fails. The turn path
  previously set nothing and inherited ``req_llm``'s 30s default, which a
  reasoning model's slow first token can exceed (measured: a 35s stall
  failed at ~30s on the turn path). Resolution mirrors
  ``provider_retries/1``: the layered ``provider_receive_timeout_ms`` in
  ``config.toml`` (project over global), the app-env override, then the
  default (120_000 — ``req_llm``'s own image value, well under the 300s
  thinking path).
  """
  @spec provider_receive_timeout_ms(String.t() | nil | t()) :: pos_integer()
  def provider_receive_timeout_ms, do: provider_receive_timeout_ms(nil)

  def provider_receive_timeout_ms(%__MODULE__{} = snapshot),
    do:
      configured_positive_count(snapshot, "provider_receive_timeout_ms") ||
        app(:provider_receive_timeout_ms, @default_provider_receive_timeout_ms)

  def provider_receive_timeout_ms(scope_root),
    do: provider_receive_timeout_ms(snapshot(scope_root))

  @doc """
  How many git checkpoints a session keeps for ``/undo`` (ADR 036).

  A checkpoint is written before every turn; ``/undo`` restores the most
  recent and drops it, so the depth bounds how far back a session can
  rewind its files. Resolution mirrors the other runtime knobs: the
  layered ``checkpoint_depth`` in ``config.toml`` (project over global),
  the app-env override, then the built-in default (1). ``0`` disables
  checkpoints entirely (``/undo`` then reports there is nothing to undo).
  """
  @spec checkpoint_depth(String.t() | nil | t()) :: non_neg_integer()
  def checkpoint_depth, do: checkpoint_depth(nil)

  def checkpoint_depth(%__MODULE__{} = snapshot) do
    configured_count(snapshot, "checkpoint_depth") ||
      app(:checkpoint_depth, @default_checkpoint_depth)
  end

  def checkpoint_depth(scope_root), do: checkpoint_depth(snapshot(scope_root))

  # A non-negative integer in the layered config, else nil (absent/invalid
  # falls through to the next source, matching max_tool_rounds/1's shape).
  defp configured_count(%__MODULE__{config: config}, key) do
    case config[key] do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  # Like `configured_count/2` but requires a POSITIVE integer: for a
  # timeout, 0 is never meaningful (it would fail every call instantly),
  # so a 0 falls through to the next source instead of being accepted.
  defp configured_positive_count(%__MODULE__{config: config}, key) do
    case config[key] do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @doc """
  Reasoning-effort override (ADR 029), or nil when unset.

  Resolution: the layered ``reasoning_effort`` in ``config.toml`` (project
  over global), else the ``:reasoning_effort`` app-env override. The value
  reaches the provider as req_llm's ``:reasoning_effort`` option (via the
  session's ``State.reasoning_effort`` and ``wire_request/2``) and is one
  of ``#{Enum.join(@reasoning_efforts, ", ")}``.

  A configured value outside that set is a **loud error**, not a silent
  no-op: a typo that changes nothing is exactly the bug this accessor
  exists to kill. Accepts a scope root or an already-read snapshot.
  """
  @spec reasoning_effort(String.t() | nil | t()) :: atom() | nil
  def reasoning_effort, do: reasoning_effort(nil)

  def reasoning_effort(%__MODULE__{} = snapshot) do
    configured_effort(snapshot) || app_effort()
  end

  def reasoning_effort(scope_root), do: reasoning_effort(snapshot(scope_root))

  defp configured_effort(%__MODULE__{config: config}) do
    effort(config["reasoning_effort"], "config.toml `reasoning_effort`")
  end

  defp app_effort, do: effort(app(:reasoning_effort, nil), "app env :reasoning_effort")

  defp effort(nil, _source), do: nil

  defp effort(value, source) when is_atom(value) do
    if value in @reasoning_effort_atoms do
      value
    else
      raise invalid_effort(value, source)
    end
  end

  defp effort(value, source) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if normalized in @reasoning_efforts do
      String.to_existing_atom(normalized)
    else
      raise invalid_effort(value, source)
    end
  end

  defp effort(value, source), do: raise(invalid_effort(value, source))

  defp invalid_effort(value, source) do
    "invalid #{source}: #{inspect(value)} (must be one of #{Enum.join(@reasoning_efforts, ", ")})"
  end

  @doc """
  The base state directory: the `:store_path` test override's parent, or
  `$XDG_STATE_HOME/coding_agent` (or `~/.local/state/coding_agent`).
  Logs and other non-session state live alongside the store DB.
  """
  @spec state_dir() :: String.t()
  def state_dir do
    case app(:store_path, nil) do
      path when is_binary(path) ->
        Path.dirname(path)

      _ ->
        base = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
        Path.join(base, "coding_agent")
    end
  end

  @doc """
  The active session store: the path of the SQLite database that holds
  many sessions (ADR 020 R16, ADR 023).

  Precedence, strongest first:

    1. the `:store_path` application-env value — the test seam, and what
       the `--store` flag sets after resolving a selector;
    2. `AGENT_STORE` (a name or a path);
    3. `config.toml` `store = "<name|path>"`;
    4. the default `state_dir()/store.db`.

  A configured selector that cannot be resolved **raises** rather than
  silently falling back — a store is a deliberate choice, and quietly
  writing sessions to the wrong database is worse than a loud failure.
  """
  @spec store_path() :: String.t()
  def store_path do
    case app(:store_path, nil) do
      path when is_binary(path) ->
        path

      _ ->
        # No explicit override: resolve the ambient selector. This reads
        # config, so the CLI tasks PIN the store at startup
        # (`select_store!/1`) and the hot paths never reach here.
        case ambient_store_path() do
          {:ok, path} -> path
          {:error, reason} -> raise store_error(ambient_selector(), reason)
        end
    end
  end

  @doc """
  The ambient store selector (no CLI flag): `AGENT_STORE`, then
  `config.toml store =`. `nil` means the default location.
  """
  @spec ambient_selector() :: String.t() | nil
  def ambient_selector do
    case System.get_env("AGENT_STORE") || snapshot(nil).config["store"] do
      selector when is_binary(selector) and selector != "" -> selector
      _ -> nil
    end
  end

  # The default store path when no selector is configured.
  defp default_store_path, do: Path.join(state_dir(), "store.db")

  defp ambient_store_path do
    case ambient_selector() do
      nil -> {:ok, default_store_path()}
      selector -> resolve_store(selector)
    end
  end

  @doc """
  Resolves a store selector — a name from `config.toml`'s `[stores]`
  table, or an absolute / `~`-rooted path — to the store DB path. Names
  are looked up; anything that is neither a known name nor a path is an
  error (never guessed). Relative paths are refused for the same reason
  sandbox mounts are: they would resolve against a varying CWD.
  """
  @spec resolve_store(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def resolve_store(selector, scope_root \\ nil) when is_binary(selector) do
    selector = String.trim(selector)
    stores = snapshot(scope_root).config["stores"] || %{}

    case Map.get(stores, selector) do
      # a named store's *value* may still be a bad path (relative)
      path when is_binary(path) ->
        expand_store_path(path)

      # not a known name: accept a path, else name the missing store
      _ ->
        if store_path?(selector),
          do: expand_store_path(selector),
          else: {:error, {:unknown_store, selector}}
    end
  end

  @doc "The configured named stores (`config.toml [stores]`)."
  @spec stores(String.t() | nil) :: %{String.t() => String.t()}
  def stores(scope_root \\ nil) do
    case snapshot(scope_root).config["stores"] do
      %{} = stores -> stores
      _ -> %{}
    end
  end

  @doc """
  Pins the active store for the process and returns the DB path, setting
  the `:store_path` app env (the same seam `store_path/0`, `Store` and
  the test suite read).

  With a `selector` (a `--store` flag value), that choice wins and an
  unresolvable one **raises** — a flag that silently fell back would
  write sessions somewhere the user did not choose. With `nil`, the
  ambient selector (`AGENT_STORE` / `config.toml store =`) is resolved,
  falling back to the default location.

  Entry points call this **once at startup**, so `store_path/0` stays a
  cheap app-env read on hot paths (the config is not re-read per frame —
  the per-frame `UserConfig.load` CPU-storm lesson).
  """
  @spec select_store!(String.t() | nil, String.t() | nil) :: String.t()
  def select_store!(selector, scope_root \\ nil)

  # An explicit selector always re-pins (the flag is the user's choice).
  def select_store!(selector, scope_root) when is_binary(selector) do
    pin_store!(selector, scope_root)
  end

  # No flag: keep an already-pinned store (the strongest layer), else
  # resolve the ambient selector / default and pin that.
  def select_store!(nil, scope_root) do
    case app(:store_path, nil) do
      path when is_binary(path) -> path
      _ -> pin_store!(ambient_selector(), scope_root)
    end
  end

  defp pin_store!(nil, _scope_root), do: put_store_path(default_store_path())

  defp pin_store!(selector, scope_root) do
    case resolve_store(selector, scope_root) do
      {:ok, path} -> put_store_path(path)
      {:error, reason} -> raise store_error(selector, reason)
    end
  end

  defp put_store_path(path) do
    Application.put_env(:coding_agent, :store_path, path)
    path
  end

  defp store_path?(selector) do
    String.starts_with?(selector, "/") or selector == "~" or String.starts_with?(selector, "~/")
  end

  # Absolute or `~`-rooted only: `Path.expand/1` resolves `~` against
  # HOME and leaves absolute paths alone; a relative path would resolve
  # against a varying CWD, so it is refused.
  defp expand_store_path(path) do
    if store_path?(path) do
      {:ok, Path.expand(path)}
    else
      {:error, {:relative_store_path, path}}
    end
  end

  defp store_error(selector, reason) do
    "cannot resolve session store #{inspect(selector)}: #{inspect(reason)}. " <>
      "Define it in config.toml [stores] or pass an absolute path."
  end

  defp app(key, default), do: Application.get_env(:coding_agent, key, default)
end
