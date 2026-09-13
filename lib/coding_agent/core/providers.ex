defmodule CodingAgent.Core.Providers do
  @moduledoc """
  Provider registry (ADR 014): `[providers.<name>]` tables in
  config.toml define how model specs `<name>:<model>` reach the wire.

  An entry with `provider = "openai"` rides that req_llm provider
  module (the ollama-cloud case: cloud models are OpenAI-compatible,
  and req_llm's native :ollama provider never sends auth). Entries
  without `provider` use req_llm's native provider of the same name.
  """

  # an indirection target must name a req_llm provider module that
  # exists (and is known to work with arbitrary OpenAI-compatible
  # backends); anything else fails closed
  @indirect_targets ~w(openai)

  @typedoc "One resolved provider entry."
  @type t :: %__MODULE__{
          name: String.t(),
          req_provider: atom(),
          backend: atom() | nil,
          base_url: String.t() | nil,
          config: %{String.t() => term()}
        }

  @enforce_keys [:name, :req_provider]
  defstruct name: nil, req_provider: nil, backend: nil, base_url: nil, config: %{}

  @doc "All configured provider names (config.toml [providers.*])."
  @spec list(%{String.t() => term()}) :: [String.t()]
  def list(config) when is_map(config) do
    config
    |> Map.get("providers", %{})
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Resolves a provider name to its wire shape. Unknown name (no table)
  falls back to the native req_llm provider of that name — the
  zero-config case (`ollama:...` with nothing in config.toml).
  """
  @spec resolve(String.t(), %{String.t() => term()}) ::
          {:ok, t()} | {:error, :unknown_provider | {:bad_entry, term()}}
  def resolve(name, config) when is_binary(name) and is_map(config) do
    entry =
      config
      |> Map.get("providers", %{})
      |> Map.get(name)

    case entry do
      nil ->
        # native: no indirection, no override — model spec passes through
        with {:ok, atom} <- native_provider(name) do
          {:ok, %__MODULE__{name: name, req_provider: atom, config: %{}}}
        end

      %{} = entry ->
        with {:ok, target} <- indirection(name, entry) do
          {:ok,
           %__MODULE__{
             name: name,
             req_provider: target,
             backend: backend(name, entry),
             base_url: entry["base_url"],
             config: entry
           }}
        end

      other ->
        {:error, {:bad_entry, other}}
    end
  end

  @doc """
  Builds the model input for `<name>:<model>` under this registry:
  a string passthrough for native providers, a `ReqLLM.model!` map
  for indirections (the map form is how base_url/backend/extra reach
  the wire).
  """
  @spec model_input(String.t(), String.t(), %{String.t() => term()}) ::
          {:ok, String.t() | %{optional(atom()) => term()}} | {:error, term()}
  def model_input(name, model_id, config) when is_binary(name) and is_binary(model_id) do
    with {:ok, p} <- resolve(name, config) do
      cond do
        # native provider: plain spec string, req_llm resolves as usual
        p.req_provider == native_atom(name) ->
          {:ok, "#{name}:#{model_id}"}

        true ->
          attrs =
            %{
              id: model_id,
              provider: p.req_provider
            }
            |> maybe_put(:base_url, p.base_url)
            |> maybe_put(:extra, p.backend && %{openai_compatible_backend: p.backend})

          {:ok, ReqLLM.model!(attrs)}
      end
    end
  end

  @doc "Provider names whose keys should be published into req_llm at boot."
  @spec publishable(%{String.t() => term()}) :: [String.t()]
  def publishable(config), do: list(config)

  defp indirection(name, entry) do
    case entry["provider"] do
      nil ->
        native_provider(name)

      target when is_binary(target) ->
        if target in @indirect_targets do
          {:ok, String.to_existing_atom(target)}
        else
          {:error, {:bad_entry, "unsupported provider indirection: #{target}"}}
        end

      other ->
        {:error, {:bad_entry, other}}
    end
  end

  defp native_provider(name) do
    atoms = ReqLLM.Providers.list()

    case Enum.find(atoms, &(Atom.to_string(&1) == name)) do
      nil -> {:error, {:bad_entry, "no req_llm provider named #{name}"}}
      atom -> {:ok, atom}
    end
  end

  defp native_atom(name) do
    atoms = ReqLLM.Providers.list()
    Enum.find(atoms, &(Atom.to_string(&1) == name)) || String.to_atom(name)
  end

  # explicit backend flag (openai_compatible_backend); an indirection
  # without one passes no extra — the registry stays blind to services
  defp backend(_name, entry) do
    case entry["backend"] do
      b when is_binary(b) -> String.to_existing_atom(b)
      _ -> nil
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
