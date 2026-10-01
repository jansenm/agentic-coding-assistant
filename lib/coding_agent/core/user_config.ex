defmodule CodingAgent.Core.UserConfig do
  @moduledoc """
  User configuration (ADR 014): four TOML files, layered.

  Global files live in `~/.config/coding-agent/` (safe to back up — no
  secrets there); credentials live in `~/.local/share/coding-agent/
  auth.toml` (the XDG data dir, matching opencode's convention); a
  project may override the non-secret files via `<scope_root>/
  .coding-agent/`.

  Layer order, weakest to strongest:

  1. built-in defaults
  2. global `~/.config/coding-agent/<file>.toml`
  3. project `<scope_root>/.coding-agent/<file>.toml`
  4. environment / CLI flags (call sites apply those after this)

  `auth.toml` is global only — never read from a project (secrets in a
  repo risk accidental commits; revisit if a real need appears).

  Fail behavior mirrors Permissions: missing files are fine, malformed
  TOML raises with the file named.
  """

  @config_dir "coding-agent"
  @data_dir "coding-agent"
  @project_dir ".coding-agent"

  # Files whose layers are merged (permissions.toml has its own loader —
  # its schema is not a plain overlay).
  @files ~w(config ui)

  @typedoc "Merged, layered config for one scope."
  @type t :: %__MODULE__{
          config: %{String.t() => term()},
          ui: %{String.t() => term()},
          permissions: CodingAgent.Core.Permissions.t(),
          layers: %{String.t() => [map()]}
        }

  defstruct config: %{}, ui: %{}, permissions: nil, layers: %{}

  # -- Paths -------------------------------------------------------------------

  @doc "Global config dir: ~/.config/coding-agent (XDG_CONFIG_HOME respected)."
  def global_dir do
    base = System.get_env("XDG_CONFIG_HOME") || Path.join(home(), ".config")
    Path.join(base, @config_dir)
  end

  @doc "Secrets dir: ~/.local/share/coding-agent (XDG_DATA_HOME respected)."
  def data_dir do
    base = System.get_env("XDG_DATA_HOME") || Path.join(home(), ".local/share")
    Path.join(base, @data_dir)
  end

  @doc """
  The project config directory for a scope root: `<scope_root>/.coding-agent`.

  The scope root is the directory the session was started in — the ONE
  directory we look at (`.coding-agent/`, `AGENTS.md`, `.git`). We do NOT
  search upward: a config meant for the repo root belongs with the session
  started at the repo root. A worktree's `.git` is a file at the scope root
  pointing elsewhere, and still resolves here.
  """
  @spec project_dir(String.t() | nil) :: String.t() | nil
  def project_dir(nil), do: nil

  def project_dir(scope_root) when is_binary(scope_root) do
    Path.join(Path.expand(scope_root), @project_dir)
  end

  defp home do
    System.get_env("HOME") || raise("HOME not set; cannot resolve config paths")
  end

  # -- Loading -----------------------------------------------------------------

  @doc """
  Loads and merges the layered config for a scope root (nil: globals
  only). Returns the merged struct. A broken TOML raises — use
  `load_safe/1` where a bad user file must only degrade (keymaps).
  """
  @spec load(String.t() | nil) :: t()
  def load(scope_root) do
    # Read each file's three layers ONCE: the merged view and the
    # per-layer view (needed by the sandbox mount schema, which must
    # keep `rw` out of the project layer) come from the same read.
    layers = Map.new(@files, &{&1, layers(scope_root, &1)})

    %__MODULE__{
      config: merged(layers["config"]),
      ui: merged(layers["ui"]),
      permissions: load_permissions(scope_root),
      layers: layers
    }
  end

  @doc """
  Like `load/1` but a broken TOML returns `{:error, message}` instead
  of raising — for paths that must degrade (keymaps mid-session).
  """
  @spec load_safe(String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def load_safe(scope_root) do
    {:ok, load(scope_root)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # (The old `model/1` accessor was dead code — `CodingAgent.model/0`
  # is the single model resolver; see Core.Config.)

  @doc """
  The three layers of one config file *separately*, weakest first:
  `[shipped, global, project]`. Unlike `load/1` these are not merged —
  the sandbox mount schema needs them apart, because `rw` may only come
  from the shipped defaults and the user layer, never from a repo config
  (ADR 015 non-elevation). A missing file yields `%{}`.
  """
  @spec layers(String.t() | nil, String.t()) :: [map()]
  def layers(scope_root, name) do
    [
      read_toml(shipped_path(name)),
      read_toml(global_path(name)),
      read_toml(project_path(scope_root, name))
    ]
  end

  # layer 0: shipped defaults, versioned with the app
  defp shipped_path(name),
    do: Path.join([Application.app_dir(:coding_agent), "priv", "coding-agent", "#{name}.toml"])

  defp global_path(name), do: Path.join(global_dir(), "#{name}.toml")

  defp project_path(nil, _name), do: nil
  defp project_path(root, name), do: Path.join(project_dir(root), "#{name}.toml")

  # Shallow merge, weakest to strongest: shipped defaults (layer 0,
  # versioned with the app) < global config < project config. Deep
  # merge for the [providers.*] table so a project can override ONE
  # provider without shadowing the shipped defaults for the rest.
  defp merged([]), do: %{}

  defp merged([first | rest]) do
    Enum.reduce(rest, first, fn layer, acc ->
      Map.merge(acc, layer, fn k, base, override -> deep_merge(k, base, override) end)
    end)
  end

  defp deep_merge(_k, base, override) when is_map(base) and is_map(override),
    do: Map.merge(base, override, &deep_merge/3)

  defp deep_merge(_k, _base, override), do: override

  defp read_toml(nil), do: %{}
  defp read_toml(path), do: read(path)

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> parse(content, path)
      {:error, :enoent} -> %{}
      {:error, reason} -> raise "cannot read #{Path.expand(path)}: #{:file.format_error(reason)}"
    end
  end

  defp parse(content, path) do
    case Toml.decode(content, keys: :strings) do
      {:ok, doc} -> doc
      {:error, reason} -> raise "invalid TOML in #{path}: #{format_toml_error(reason)}"
    end
  end

  defp format_toml_error(%Toml.Error{} = e), do: Exception.message(e)
  defp format_toml_error({:invalid_toml, msg}), do: msg
  defp format_toml_error(other), do: inspect(other)

  # -- Permissions -------------------------------------------------------------

  # The project policy file is `.coding-agent/permissions.toml` (ADR 014).
  # The pre-ADR-014 `agent-permissions.toml` is NOT read — unreleased
  # software does not carry legacy (AGENTS.md: no backwards compatibility).
  defp load_permissions(nil) do
    CodingAgent.Core.Permissions.load(global_path("permissions"), nil)
  end

  defp load_permissions(scope_root) do
    CodingAgent.Core.Permissions.load(
      global_path("permissions"),
      project_path(scope_root, "permissions")
    )
  end

  # -- Credentials (auth.toml, global only) --------------------------------------

  @doc """
  Resolves a credential for `provider`, strongest first:

  1. env var `<PROVIDER>_API_KEY` (uppercase; e.g. OLLAMA_API_KEY)
  2. `auth.toml` `[<provider>] api_key`

  Returns `{:ok, %{api_key: key}}` or `{:error, reason}` — `:none`
  when the provider has no entry at all (the caller decides whether
  that means keyless-connect or fail).
  """
  @spec credential(String.t()) :: {:ok, %{api_key: String.t()}} | {:error, :none | term()}
  def credential(provider) when is_binary(provider) do
    env_name = String.upcase(provider) <> "_API_KEY"

    case System.get_env(env_name) do
      key when is_binary(key) and key != "" ->
        {:ok, %{api_key: key}}

      _ ->
        case auth_entry(provider) do
          %{"api_key" => key} when is_binary(key) and key != "" -> {:ok, %{api_key: key}}
          _ -> {:error, :none}
        end
    end
  end

  # Connection info lives in config.toml `[providers.<name>]`; auth.toml
  # holds keys ONLY (ADR 014 revision: the credential file is a password
  # file, nothing else).

  @doc "Endpoint override for `provider` (config.toml [providers.<name>] base_url), if any."
  @spec base_url(String.t(), %{String.t() => term()}) :: String.t() | nil
  def base_url(provider, config) when is_binary(provider) and is_map(config) do
    config
    |> Map.get("providers", %{})
    |> Map.get(provider, %{})
    |> case do
      %{"base_url" => url} when is_binary(url) -> url
      _ -> nil
    end
  end

  defp auth_entry(provider) do
    auth = read(Path.join(data_dir(), "auth.toml"))
    Map.get(auth, provider) || %{}
  end
end
