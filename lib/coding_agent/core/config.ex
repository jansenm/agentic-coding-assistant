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
  alias CodingAgent.Core.Compaction
  alias CodingAgent.Core.Sandbox.Mounts
  alias CodingAgent.Core.UserConfig

  # -- Runtime knob defaults (the single source; config/config.exs no
  # longer repeats these). ------------------------------------------------

  @default_max_tool_rounds 100
  @default_context_window_tokens 500_000
  @default_compaction_wall_clock_ms 300_000
  @default_compaction_inactivity_ms 120_000

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

  @doc "Per-turn tool-round guard (catches a single runaway loop, not normal work)."
  @spec max_tool_rounds() :: pos_integer()
  def max_tool_rounds, do: app(:max_tool_rounds, @default_max_tool_rounds)

  @doc """
  Absolute compaction trigger in tokens. The default lives in
  `Compaction.default_trigger_tokens/0` (one source).
  """
  @spec compaction_trigger_tokens() :: pos_integer()
  def compaction_trigger_tokens,
    do: app(:compaction_trigger_tokens, Compaction.default_trigger_tokens())

  @doc "Hard wall-clock bound on the summarize call, in milliseconds."
  @spec compaction_wall_clock_ms() :: pos_integer()
  def compaction_wall_clock_ms,
    do: app(:compaction_wall_clock_ms, @default_compaction_wall_clock_ms)

  @doc "Inactivity bound inside the summarize call, in milliseconds."
  @spec compaction_inactivity_ms() :: pos_integer()
  def compaction_inactivity_ms,
    do: app(:compaction_inactivity_ms, @default_compaction_inactivity_ms)

  @doc "Context window of the configured model, in tokens (sidebar %)."
  @spec context_window_tokens() :: pos_integer()
  def context_window_tokens,
    do: app(:context_window_tokens, @default_context_window_tokens)

  @doc "Reasoning-effort override (config.toml or app env), or nil."
  @spec reasoning_effort() :: String.t() | nil
  def reasoning_effort, do: app(:reasoning_effort, nil)

  @doc """
  The base state directory: the `:store_dir` test override's parent, or
  `$XDG_STATE_HOME/coding_agent` (or `~/.local/state/coding_agent`).
  Logs and other non-session state live alongside `sessions/`.
  """
  @spec state_dir() :: String.t()
  def state_dir do
    case app(:store_dir, nil) do
      dir when is_binary(dir) ->
        Path.dirname(dir)

      _ ->
        base = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
        Path.join(base, "coding_agent")
    end
  end

  @doc """
  The session storage directory. The `:store_dir` app-env override (a
  test seam) points here directly; otherwise `state_dir()/sessions`.
  """
  @spec store_dir() :: String.t()
  def store_dir do
    case app(:store_dir, nil) do
      dir when is_binary(dir) -> dir
      _ -> Path.join(state_dir(), "sessions")
    end
  end

  defp app(key, default), do: Application.get_env(:coding_agent, key, default)
end
