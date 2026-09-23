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
