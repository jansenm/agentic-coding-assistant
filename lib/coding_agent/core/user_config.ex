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

  @files ~w(config ui permissions)

  @typedoc "Merged, layered config for one scope."
  @type t :: %__MODULE__{
          config: %{String.t() => term()},
          ui: %{String.t() => term()},
          permissions: CodingAgent.Core.Permissions.t()
        }

  defstruct config: %{}, ui: %{}, permissions: nil

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

  defp project_dir(scope_root) when is_binary(scope_root),
    do: Path.join(scope_root, @project_dir)

  @doc false
  # test visibility helper: the project config dir for a scope root
  def project_dir_for_test(scope_root), do: project_dir(scope_root)

  defp home do
    System.get_env("HOME") || raise("HOME not set; cannot resolve config paths")
  end

  # -- Loading -----------------------------------------------------------------

  @doc """
  Loads and merges the layered config for a scope root (nil: globals
  only). Returns the merged struct.
  """
  @spec load(String.t() | nil) :: t()

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

  def load(scope_root) do
    config =
      for name <- @files, into: %{} do
        {name,
         merged_map(
           shipped_path(name),
           global_path(name),
           project_path(scope_root, name)
         )}
      end

    %__MODULE__{
      config: config["config"],
      ui: config["ui"],
      permissions: load_permissions(scope_root)
    }
  end

  @doc "Default model: config `model` (project over global) as a string."
  def model(%__MODULE__{config: c}),
    do: Map.get(c, "model") || Application.get_env(:coding_agent, :model)

  # layer 0: shipped defaults, versioned with the app
  defp shipped_path(name),
    do: Path.join([Application.app_dir(:coding_agent), "priv", "coding-agent", "#{name}.toml"])

  defp global_path(name), do: Path.join(global_dir(), "#{name}.toml")

  defp project_path(nil, _name), do: nil
  defp project_path(root, name), do: Path.join(project_dir(root), "#{name}.toml")

  # shallow merge, weakest to strongest: shipped defaults (layer 0,
  # versioned with the app) < global config < project config. Deep
  # merge for the [providers.*] table so a project can override ONE
  # provider without shadowing the shipped defaults for the rest.
  defp merged_map(shipped, global, project) do
    shipped
    |> read_toml()
    |> Map.merge(read_toml(global), &deep_merge/3)
    |> Map.merge(read_toml(project), &deep_merge/3)
  end

  defp deep_merge(_k, base, override) when is_map(base) and is_map(override),
    do: Map.merge(base, override)

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

  # project file moved into .coding-agent/ (ADR 014); the old
  # agent-permissions.toml at the scope root is still read (after) for
  # the transition. User layer: global permissions.toml.
  defp load_permissions(nil) do
    CodingAgent.Core.Permissions.load(global_path("permissions"), nil)
  end

  defp load_permissions(scope_root) do
    new_file = project_path(scope_root, "permissions")
    legacy = Path.join(scope_root, "agent-permissions.toml")
    legacy = if File.exists?(legacy) and not File.exists?(new_file), do: legacy, else: nil

    CodingAgent.Core.Permissions.load(global_path("permissions"), new_file || legacy)
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
