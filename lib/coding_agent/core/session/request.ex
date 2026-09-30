defmodule CodingAgent.Core.Session.Request do
  @moduledoc """
  Wire-request assembly (ADR 014): model spec + `[providers.*]`
  snapshot + credentials → `(model_input, opts)` for one ReqLLM call.

  Every LLM call site goes through here — the turn loop (streaming)
  and the compactor (one non-streaming summarize call) — so both
  resolve providers, credentials and base URLs exactly the same way.
  The model spec's first segment names a `[providers.*]` entry (or a
  native req_llm provider when the registry has no such table).
  Credentials: env first, then the global auth.toml. A provider with
  no credential connects keyless (local ollama proxy); one with a
  credential sends it.

  Plain data in, error tuples out — nothing here raises; the caller
  fails the turn.
  """

  alias CodingAgent.Core.{Config, Providers, UserConfig}

  @doc """
  Assembles the call for the given model spec under the given
  provider-config snapshot. Returns `{:ok, model_input, opts}` or an
  error tuple (unknown provider, bad entry).

  The transport inactivity timeout (`receive_timeout`, ADR 041) is set
  here — once, for BOTH call sites (the turn loop and the compactor's
  summarize call) — so neither inherits `req_llm`'s 30s default and the
  two cannot drift. The compactor still overrides it with its own
  inactivity budget for the summarize call.
  """
  @spec build(String.t() | nil, %{String.t() => term()} | nil) ::
          {:ok, String.t() | map(), keyword()} | {:error, term()}
  def build(model, provider_config) do
    [name | rest] = String.split(model || "", ":", parts: 2)
    model_id = Enum.at(rest, 0) || ""
    cfg = provider_config || %{}

    with {:ok, model_input} <- Providers.model_input(name, model_id, cfg),
         {:ok, opts} <- call_opts(name, cfg) do
      {:ok, model_input,
       Keyword.put(opts, :receive_timeout, Config.provider_receive_timeout_ms())}
    end
  end

  # Credentials: env first, then keyless.
  defp call_opts(provider, cfg) do
    case UserConfig.credential(provider) do
      {:ok, %{api_key: key}} -> {:ok, with_url(provider, cfg, api_key: key)}
      {:error, :none} -> {:ok, with_url(provider, cfg, [])}
    end
  end

  # A resolved base_url (e.g. ollama cloud behind provider = "openai")
  # rides the opts; req_llm resolves the rest.
  defp with_url(provider, cfg, opts) do
    case Providers.resolve(provider, cfg) do
      {:ok, %Providers{base_url: url}} when is_binary(url) ->
        Keyword.put(opts, :base_url, url)

      _ ->
        opts
    end
  end
end
