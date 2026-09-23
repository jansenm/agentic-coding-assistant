defmodule CodingAgent.Core.Failure do
  @moduledoc """
  Classification of a failed turn or provider probe into a category and
  a human hint (ADR 008: this is domain knowledge, not view knowledge).

  Before this module the TUI (`classify_failure/1`, `classify_reason/1`)
  and `ProviderHealth` (`classify/1`, `humanize/1`) each answered the
  same question independently — two tables of transport/auth markers,
  free to drift. The categories:

    * `:local`    — the request never left correctly: a build/encoding
      failure on OUR side (e.g. an invalid UTF-8 byte in the context).
      Naming the provider here is actively misleading.
    * `:provider` — the request reached the wire and the provider or
      transport answered badly (connection refused, 401/403, 429, 5xx,
      DNS, timeouts).
    * `:other`    — anything not placeable; keep the reason, make no claim.

  `classify/1` is the one classifier, consumed by both the TUI and
  `ProviderHealth`.
  """

  @local_markers [
    "Failed to build streaming request",
    "invalid byte",
    "invalid utf-8",
    "cannot encode",
    "Jason.EncodeError"
  ]

  @provider_markers [
    "econnrefused",
    "connection refused",
    "nxdomain",
    "name not known",
    "timeout",
    "timed out",
    "401",
    "403",
    "429",
    "500",
    "502",
    "503",
    "504"
  ]

  @typedoc "Failure category."
  @type kind :: :local | :provider | :other

  @doc """
  Classifies a wrapped turn-failure reason into `{kind, hint}`.

  `reason` arrives wrapped: `{:stream_error, %ReqLLM.Error.API.Stream{}}`,
  `{:provider_build_failed, %ReqLLM.Error.API.Request{}}`,
  `{:http_streaming_failed, inner}`, plain structs/maps, strings or atoms.
  A nil / unplaceable reason is `:other` with no claim.
  """
  @spec classify(term()) :: {kind(), String.t()}
  def classify({:stream_error, err}), do: classify(err)
  def classify({:provider_build_failed, err}), do: classify(err)
  def classify({:http_streaming_failed, inner}), do: classify(inner)

  def classify(%{reason: reason}) when is_binary(reason), do: classify_reason(reason)
  def classify(reason) when is_binary(reason), do: classify_reason(reason)

  def classify(%{reason: reason}) when is_atom(reason) and not is_nil(reason),
    do: classify(to_string(reason))

  def classify(_), do: {:other, "the session is idle again; retry"}

  @doc """
  Classifies an unwrapped reason string. Public so both consumers can
  share the marker tables and so the tables are testable.
  """
  @spec classify_reason(String.t()) :: {kind(), String.t()}
  def classify_reason(reason) when is_binary(reason) do
    down = String.downcase(reason)

    cond do
      contains_any?(down, @local_markers) ->
        {:local, "this is a local request-build failure; retry or start a new session"}

      contains_any?(down, @provider_markers) ->
        {:provider, "check the provider and retry"}

      true ->
        {:other, "the session is idle again; retry"}
    end
  end

  @doc """
  A human sentence for a provider-probe error (`ProviderHealth`), reusing
  the same classifier. Auth/quota statuses are named explicitly, transport
  causes are humanized, and anything else keeps the raw reason so nothing
  reads as a generic "unknown error".
  """
  @spec provider_reason(term()) :: String.t()
  def provider_reason(%{status: 401}),
    do: "provider rejected the credentials (401) — check the API key"

  def provider_reason(%{status: 403}),
    do: "provider rejected the credentials (403) — check the API key"

  def provider_reason(%{status: 429}), do: "provider quota exceeded (429)"
  def provider_reason(other), do: provider_reason_from(other)

  defp provider_reason_from(%{reason: reason}) when is_binary(reason), do: humanize(reason)
  defp provider_reason_from(other), do: "provider error: #{inspect(other)}"

  defp humanize(reason) do
    cond do
      reason =~ "econnrefused" or reason =~ "connection refused" ->
        "could not reach the provider (connection refused)"

      reason =~ "timeout" or reason =~ "timed out" ->
        "provider did not answer in time"

      reason =~ "nxdomain" ->
        "provider host not found (DNS)"

      reason =~ "refused" or reason =~ "unreachable" ->
        "could not reach the provider"

      true ->
        String.split(reason, "%") |> List.first() |> String.trim()
    end
  end

  defp contains_any?(haystack, needles), do: Enum.any?(needles, &String.contains?(haystack, &1))
end
