defmodule CodingAgent.Core.Costs do
  @moduledoc """
  What the provider says was spent — never what a price table thinks it
  should have cost.

  A local rate table rots in three ways at once: it is wrong for a model
  you switch to, it is wrong for the cached rate you did not model, and it
  is wrong for the hours a provider bills at peak rates. Ollama Cloud
  publishes exactly that two-tier schedule (`deepseek-v4.1-flash` at
  $0.30/$0.006/$1.20 per Mtok in peak hours, half that off-peak), so any
  single number written into a config file is wrong half the day. The
  provider's own accounting already has all of that inside it.

  Two reads, both at the HOST of the provider's `base_url` (the `/v1` is
  the chat wire, not the billing one):

    * `GET /api/usage?range=24h` — hourly buckets plus a `totals` object
      with `usage_usd` and the token counts. **Differencing two samples is
      money actually spent**, discounts and peak pricing included; the
      harness never multiplies tokens by a rate.
    * `GET /api/balance` — the remaining included allowance and purchased
      credits for the period. Documented limit: 10 requests per minute
      per user, shared across keys and devices, so this is polled once
      per turn and a `429` keeps the previous value.

  The probe is derived, not declared: the endpoints belong to the host, so
  a local daemon (`base_url` at localhost) has no probe and a local model
  costs nothing. A provider whose billing API stops following its wire
  (OpenRouter: OpenAI-shaped chat, `/api/v1/credits`) is the case that
  earns an explicit `usage = "<dialect>"` field, shaped like `discover`.

  Nothing here invents: no probe, no credential or an unexpected body
  means no number, and the sidebar keeps hiding the row.
  """

  alias CodingAgent.Core.{Providers, UserConfig}

  @type snapshot :: %{
          usd: float(),
          input: non_neg_integer(),
          cached: non_neg_integer(),
          output: non_neg_integer(),
          requests: non_neg_integer()
        }

  @type balance :: %{
          remaining: float(),
          allowance: float() | nil,
          purchased: float(),
          from: String.t() | nil,
          until: String.t() | nil
        }

  # Billing APIs are a property of the HOST, not of the wire dialect. One
  # entry per vendor that publishes them; a host that is absent has no
  # probe and therefore no cost display.
  @billing_hosts %{"ollama.com" => :ollama}

  @timeout_ms 1_500

  @doc """
  The provider host that serves a billing API for this model, if any.

  Derived from the resolved `base_url` (never from config: a host is
  either the vendor's or it is not). `:none` for a native provider with no
  `base_url`, for a local daemon, and for a host we do not know.
  """
  @spec target(String.t() | nil, %{String.t() => term()}) :: {:ok, atom(), String.t()} | :none
  def target(model, provider_config) do
    [provider | _] = String.split(model || "", ":", parts: 2)

    with {:ok, %Providers{base_url: url}} when is_binary(url) <-
           Providers.resolve(provider, provider_config || %{}),
         {:ok, %URI{scheme: scheme, host: host}} <- URI.new(url),
         true <- scheme in ~w(http https),
         {:ok, dialect} <- Map.fetch(@billing_hosts, host) do
      {:ok, dialect, origin(url)}
    else
      _ -> :none
    end
  end

  @doc """
  The account's 24 h totals: money spent and tokens, as the provider
  counts them. `opts[:get]` injects the transport for tests.
  """
  @spec snapshot(String.t() | nil, %{String.t() => term()}, keyword()) ::
          {:ok, snapshot()} | :none | {:error, term()}
  def snapshot(model, provider_config, opts \\ []) do
    with {:ok, _dialect, origin} <- target(model, provider_config),
         {:ok, %{api_key: key}} <- credential(model, opts),
         {:ok, status, body} <- fetch(origin <> "/api/usage?range=24h", key, opts) do
      case status do
        200 -> parse_snapshot(body)
        other -> {:error, {:http, other}}
      end
    else
      :none -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The account's remaining credits for the current period. Legacy plans
  (percent limits instead of dollars) yield `:none` rather than a
  fabricated dollar figure.
  """
  @spec balance(String.t() | nil, %{String.t() => term()}, keyword()) ::
          {:ok, balance()} | :none | {:error, term()}
  def balance(model, provider_config, opts \\ []) do
    with {:ok, _dialect, origin} <- target(model, provider_config),
         {:ok, %{api_key: key}} <- credential(model, opts),
         {:ok, status, body} <- fetch(origin <> "/api/balance", key, opts) do
      case status do
        200 -> parse_balance(body)
        429 -> {:error, :rate_limited}
        other -> {:error, {:http, other}}
      end
    else
      :none -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  # The credential chain is the session's own (`<PROVIDER>_API_KEY`, then
  # `auth.toml`): billing reads the same key the chat does, so there is
  # nothing extra to configure and nothing extra to leak. `opts[
  # :credential]` is the test seam — a test must not depend on the
  # machine's auth file.
  defp credential(model, opts) do
    case Keyword.get(opts, :credential) do
      nil ->
        [provider | _] = String.split(model || "", ":", parts: 2)
        UserConfig.credential(provider)

      injected ->
        injected
    end
  end

  defp fetch(url, key, opts) do
    case Keyword.get(opts, :get, &http_get/2).(url, key) do
      {:ok, status, body} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_get(url, key) do
    case Req.get(url,
           headers: [{"authorization", "Bearer " <> key}],
           receive_timeout: @timeout_ms,
           connect_options: [timeout: @timeout_ms]
         ) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_snapshot(%{
         "totals" => %{
           "usage_usd" => usd,
           "input_tokens" => input,
           "cached_input_tokens" => cached,
           "output_tokens" => output,
           "request_count" => requests
         }
       })
       when is_number(usd) and is_integer(input) and is_integer(cached) and is_integer(output) and
              is_integer(requests) do
    {:ok,
     %{
       usd: usd * 1.0,
       input: input,
       cached: cached,
       output: output,
       requests: requests
     }}
  end

  defp parse_snapshot(_), do: {:error, :unexpected_body}

  # Modern plans report dollars; legacy plans report `session`/`weekly`
  # percentages, which cannot be turned into money. Say nothing instead.
  defp parse_balance(%{"included" => %{"balance_usd" => remaining} = included} = body)
       when is_number(remaining) do
    purchased =
      case body do
        %{"purchased" => %{"balance_usd" => p}} when is_number(p) -> p * 1.0
        _ -> 0.0
      end

    {from, until} =
      case included do
        %{"period" => %{"from" => f, "until" => u}} when is_binary(f) and is_binary(u) -> {f, u}
        _ -> {nil, nil}
      end

    {:ok,
     %{
       remaining: remaining * 1.0,
       allowance: number_or_nil(included["allowance_usd"]),
       purchased: purchased,
       from: from,
       until: until
     }}
  end

  defp parse_balance(_), do: :none

  defp number_or_nil(n) when is_number(n), do: n * 1.0
  defp number_or_nil(_), do: nil

  # scheme://host[:port], no path: `https://ollama.com/v1` and
  # `https://ollama.com` name the same origin, and that is where the
  # billing endpoints live.
  defp origin(url) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    port = if port in [nil, 80, 443], do: "", else: ":#{port}"
    "#{scheme}://#{host}#{port}"
  end
end
