defmodule CodingAgent.Application do
  @moduledoc """
  OTP application for the coding agent.

  Supervision tree per ADR 003/008: the process
  registries, the user-interrupt coordinator (its ETS flag/handle table
  must outlive the process that raises the stop), the compaction
  summarize-task supervisor (compaction tasks must NOT be linked to the
  session process — a provider-stack crash inside the summarize call is
  contained there) and the dynamic session supervisor.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    publish_keys()
    check_sandbox()

    children = [
      {Registry, keys: :unique, name: CodingAgent.Registry},
      {Registry,
       keys: :duplicate, name: CodingAgent.EventRegistry, partitions: System.schedulers_online()},
      CodingAgent.Core.Interrupt,
      CodingAgent.Core.Session.Compactor.TaskSupervisor,
      CodingAgent.Core.Session.TurnTaskSupervisor,
      CodingAgent.Core.Session.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CodingAgent.Supervisor)
  end

  # Startup sandbox check (ADR 015). The configured implementation may be
  # confining (bwrap) but unusable on this machine — no binary, or
  # unprivileged user namespaces disabled by host hardening. We do not
  # abort: the effective implementation falls back to Sandbox.None, and
  # because `Sandbox.confines?/0` is then false the gate keeps asking for
  # every shell/git call, i.e. the pre-ADR-015 behaviour. The check is
  # purely so the condition is not silent.
  defp check_sandbox do
    case CodingAgent.Core.Sandbox.diagnose() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "sandbox: confinement requested but unavailable — running unconfined " <>
            "(shell/git will ask for approval). Reason: #{reason}"
        )
    end
  end

  # Push auth.toml credentials into req_llm's app env so req_llm's own
  # key resolution chain finds them (put_key(:<provider>_api_key, ...)).
  # A real env var wins: when one is set we publish nothing (req_llm
  # prefers app env over env var, so publishing would shadow it).
  # Providers come from config.toml [providers.*] (ADR 014); the
  # provider = "openai" indirection publishes under :openai_api_key too
  # (cloud models ride that provider — req_llm's :ollama never sends
  # auth).
  defp publish_keys do
    cfg = CodingAgent.Core.Config.snapshot(nil).config

    for provider <- CodingAgent.Core.Providers.list(cfg) do
      env_name = String.upcase(provider) <> "_API_KEY"

      if System.get_env(env_name) in [nil, ""] do
        case CodingAgent.Core.UserConfig.credential(provider) do
          {:ok, %{api_key: key}} ->
            ReqLLM.put_key(String.to_atom("#{provider}_api_key"), key)
            publish_indirect_keys(provider, key, cfg)

          _ ->
            :ok
        end
      end
    end
  end

  defp publish_indirect_keys(provider, key, cfg) do
    case CodingAgent.Core.Providers.resolve(provider, cfg) do
      {:ok, %CodingAgent.Core.Providers{req_provider: :openai}} ->
        ReqLLM.put_key(:openai_api_key, key)

      _ ->
        :ok
    end
  end
end
