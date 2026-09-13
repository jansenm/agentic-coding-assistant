defmodule CodingAgent.Application do
  @moduledoc """
  OTP application for the coding agent.

  Supervision tree per ADR 003/008: today only the process registry the
  session layer will use; the session supervisor joins in phase 1 work.
  """

  use Application

  @impl true
  def start(_type, _args) do
    publish_keys()

    children = [
      {Registry, keys: :unique, name: CodingAgent.Registry},
      {Registry,
       keys: :duplicate, name: CodingAgent.EventRegistry, partitions: System.schedulers_online()},
      CodingAgent.Core.Session.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CodingAgent.Supervisor)
  end

  # Push auth.toml credentials into req_llm's app env so req_llm's own
  # key resolution chain finds them (put_key(:<provider>_api_key, ...)).
  # A real env var wins: when one is set we publish nothing (req_llm
  # prefers app env over env var, so publishing would shadow it).
  defp publish_keys do
    for provider <- ~w(ollama anthropic openai openrouter) do
      env_name = String.upcase(provider) <> "_API_KEY"

      if System.get_env(env_name) in [nil, ""] do
        case CodingAgent.Core.UserConfig.credential(provider) do
          {:ok, %{api_key: key}} ->
            ReqLLM.put_key(String.to_atom("#{provider}_api_key"), key)

            # cloud-direct mode (ADR 014): the ollama entry with an
            # ollama.com base_url drives cloud models through the
            # :openai provider (openai_compatible_backend: :ollama) —
            # req_llm's :ollama provider never sends auth. The key
            # must be visible to that provider too.
            if provider == "ollama" and
                 (CodingAgent.Core.UserConfig.base_url("ollama") || "")
                 |> String.contains?("ollama.com") do
              ReqLLM.put_key(:openai_api_key, key)
            end

          _ ->
            :ok
        end
      end
    end
  end
end
