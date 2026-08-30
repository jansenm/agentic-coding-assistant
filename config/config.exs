import Config

# CodeingAgent configuration (ADR 008): collect knobs here while the
# application grows; secrets come from the environment, never this file.

config :coding_agent,
  # req_llm model spec. Ollama (incl. cloud models via `:cloud` suffix)
  # needs no API key; see .env.example for providers that do.
  model: "ollama:glm-5.3-flash:cloud",
  # environment variable holding the provider API key (ADR 008: secrets
  # come from the environment, never from config files). Cloud ollama
  # models are not in req_llm's catalog; suppress the unverified warning.
  api_key_env: "ANTHROPIC_API_KEY"

config :req_llm, warn_unverified_models: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
