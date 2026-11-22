# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.ProviderHealth do
  @moduledoc """
  One-shot provider reachability check at TUI start (user request:
  'when i start the app i REALLY would like to be told if my provider
  is down').

  Provider-AGNOSTIC by construction: the probe is a minimal real
  completion through ReqLLM itself — the same code path a real turn
  takes (DNS, TLS, auth, quota, model). We deliberately do NOT ping
  provider endpoints ourselves; that knowledge belongs to req_llm's
  provider modules, and a TCP ping would lie anyway (up-but-401 looks
  like down).

  Cost: one minimal completion at startup. No interval, no steady-state
  traffic — 'if it disappears while using the app i got unlucky.'

  Failure classification maps to a human sentence, not just red:
  transport -> could not reach the provider; 401/403 -> credentials
  rejected; 429 -> quota. Anything else carries the raw reason.
  """

  alias ReqLLM.Context

  # req_llm option names: :max_tokens (output cap), :max_retries
  # (NimbleOptions rejected :max_output_tokens/:retries — found live
  # on the first probe run)
  @probe_opts [
    max_tokens: 1,
    stream: false,
    receive_timeout: 10_000,
    max_retries: 0
  ]

  @doc """
  Runs the probe for `model` and broadcasts `{:provider_status, :up}`
  or `{:provider_status, :down, human_reason}` on the session's event
  registry, so every subscribed view (TUI now, others later) learns
  the provider state at startup. Fire-and-forget: spawn it, never
  await it.
  """
  def check_async(model, session_id) do
    Task.start(fn ->
      case probe_model(model, session_id) do
        :ok ->
          broadcast(session_id, {:provider_status, :up})

        {:error, reason} ->
          broadcast(session_id, {:provider_status, :down, reason})
      end
    end)
  end

  @doc """
  Probes `model` (a `provider:model` spec) through the SAME registry
  path a real turn takes: Providers.resolve with the session's
  provider_config snapshot. Passing the raw spec string to req_llm
  bypasses the registry — indirected providers (provider = "openai"
  tables) have no native req_llm module and the probe reported
  'provider unavailable' for perfectly reachable setups (found live).
  """
  def probe_model(model, session_id) do
    cfg =
      case CodingAgent.Core.Session.state(session_id) do
        {:ok, st} -> st.provider_config || %{}
        _ -> %{}
      end

    [provider, model_id] = String.split(model || "", ":", parts: 2)

    with {:ok, model_input} <-
           CodingAgent.Core.Providers.model_input(provider, model_id, cfg) do
      probe_opts =
        case CodingAgent.Core.UserConfig.credential(provider) do
          {:ok, %{api_key: key}} -> [api_key: key]
          _ -> []
        end

      probe(model_input, probe_opts)
    else
      {:error, reason} -> {:error, "provider error: #{inspect(reason, printable_limit: 80)}"}
    end
  end

  @doc "Synchronous probe: :ok | {:error, human_reason}."
  def probe(model, extra_opts \\ []) do
    context =
      Context.new()
      |> Context.append(ReqLLM.Context.user("Reply with the single word: ok"))

    case ReqLLM.generate_text(model, context, @probe_opts ++ extra_opts) do
      {:ok, _response} -> :ok
      {:error, err} -> {:error, CodingAgent.Core.Failure.provider_reason(err)}
    end
  catch
    kind, value -> {:error, "probe crashed (#{inspect(kind)}): #{inspect(value)}"}
  end

  defp broadcast(session_id, event), do: CodingAgent.Core.Events.publish(session_id, event)
end
