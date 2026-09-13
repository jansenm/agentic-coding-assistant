defmodule CodingAgent.Core.Providers.Discovery do
  @moduledoc """
  Model-list sources for the model menu (ADR 014): a provider entry's
  `discover` field names a dialect —

    "openai"  GET base_url + "/models"    (the standard every
                                          OpenAI-compatible proxy speaks:
                                          litellm, vLLM, ollama compat)
    "ollama"  GET base_url + "/api/tags"  (native ollama)

  Catalog providers (openai, anthropic, ...) need none — their lists
  come from req_llm's catalog. Auth rides the same credential chain as
  sessions (env -> auth.toml -> none). Results are cached per process
  for the TUI's lifetime (one fetch per menu open, not per keystroke).
  """

  alias CodingAgent.Core.{Providers, UserConfig}

  @timeout_ms 3_000

  @type model_entry :: %{id: String.t(), source: :catalog | :discovered}

  @doc """
  Model candidates for `<provider>:` — catalog (req_llm) plus, for
  providers declaring `discover`, a live fetch. Errors degrade to a
  note, never raise: the menu must open even with the server down.
  """
  @spec models(String.t(), %{String.t() => term()}) ::
          {:ok, %{entries: [model_entry()], note: String.t() | nil}}
  def models(provider, config) when is_binary(provider) and is_map(config) do
    {catalog, catalog_note} = catalog_models(provider)
    {discovered, discover_note} = discovered_models(provider, config)

    entries =
      (catalog ++ discovered)
      |> Enum.uniq_by(& &1.id)

    {:ok, %{entries: entries, note: note(catalog_note, discover_note)}}
  end

  @doc "Fetch once, cache in the calling process (the TUI's menu path)."
  def models_cached(provider, config) do
    cache_key = {:__discovery_cache__, provider}

    case Process.get(cache_key) do
      nil ->
        result = models(provider, config)
        Process.put(cache_key, result)
        result

      cached ->
        cached
    end
  end

  @doc "Drop this process's discovery cache (config reload, manual retry)."
  def invalidate(provider \\ :all) do
    if provider == :all do
      Process.get()
      |> Map.keys()
      |> Enum.each(&Process.delete/1)
    else
      Process.delete({:__discovery_cache__, provider})
    end

    :ok
  end

  # -- catalog ---------------------------------------------------------------

  defp catalog_models(provider) do
    case catalog_scope(provider) do
      nil ->
        {[], nil}

      scope ->
        models = ReqLLM.available_models(scope: scope)

        entries = Enum.map(models, &%{id: model_id(&1), source: :catalog})
        {entries, nil}
    end
  rescue
    e -> {[], "catalog: #{Exception.message(e)}"}
  end

  defp catalog_scope(provider) do
    # a scope exists only for native catalog providers; indirections
    # (provider = "openai") and unknown names have no req_llm catalog
    atom = String.to_existing_atom(provider)
    if provider in ReqLLM.Providers.list(), do: atom
  rescue
    ArgumentError -> nil
  end

  defp model_id(%{id: id}) when is_binary(id), do: id
  defp model_id(m) when is_map(m), do: Map.get(m, :id) |> to_string()

  # -- discovered ------------------------------------------------------------

  defp discovered_models(provider, config) do
    with {:ok, resolved} <- Providers.resolve(provider, config),
         {:ok, dialect} <- discover_field(resolved),
         {:ok, base} <- base_url(resolved),
         {:ok, ids} <- fetch(dialect, base, credential(provider)) do
      {Enum.map(ids, &%{id: &1, source: :discovered}), nil}
    else
      {:error, :no_discover} -> {[], nil}
      {:error, reason} -> {[], "#{provider}: #{inspect(reason)}"}
    end
  end

  defp discover_field(%Providers{config: cfg}) do
    case cfg["discover"] do
      d when is_binary(d) and d in ~w(openai ollama) -> {:ok, d}
      d when is_binary(d) -> {:error, "unknown discover dialect #{inspect(d)}"}
      nil -> {:error, :no_discover}
    end
  end

  defp base_url(%Providers{base_url: url}) when is_binary(url), do: {:ok, url}
  defp base_url(%Providers{name: name}), do: {:error, "no base_url for #{name}"}

  defp credential(provider) do
    case UserConfig.credential(provider) do
      {:ok, %{api_key: key}} -> {:ok, key}
      _ -> :none
    end
  end

  @doc false
  def fetch("openai", base, auth), do: get(join_models(base), auth, &openai_ids/1)
  def fetch("ollama", base, auth), do: get(join_tags(base), auth, &ollama_ids/1)

  defp join_models(base), do: String.trim_trailing(base, "/") <> "/models"
  defp join_tags(base), do: String.trim_trailing(base, "/") <> "/api/tags"

  defp get(url, auth, extract) do
    headers =
      case auth do
        {:ok, key} -> [{"authorization", "Bearer #{key}"}]
        :none -> []
      end

    case Req.get(url,
           headers: headers,
           receive_timeout: @timeout_ms,
           max_retries: 0,
           retry: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, extract.(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status} from discovery"}

      {:error, err} ->
        {:error, Exception.message(err)}
    end
  end

  # "data":[{"id":"gpt-4",...},...]
  defp openai_ids(%{"data" => entries}) when is_list(entries) do
    entries
    |> Enum.map(&Map.get(&1, "id"))
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
  end

  defp openai_ids(_), do: []

  # "models":[{"name":"qwen3:14b",...},...]
  defp ollama_ids(%{"models" => entries}) when is_list(entries) do
    entries
    |> Enum.map(&Map.get(&1, "name"))
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
  end

  defp ollama_ids(_), do: []

  defp note(nil, nil), do: nil
  defp note(nil, d), do: d
  defp note(c, nil), do: c
  defp note(c, d), do: c <> "; " <> d
end
