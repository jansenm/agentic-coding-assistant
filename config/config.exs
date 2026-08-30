import Config

# CodeingAgent configuration (ADR 008): collect knobs here while the
# application grows; secrets come from the environment, never this file.

config :coding_agent,
  # req_llm model spec, e.g. "anthropic:claude-haiku-4-5"
  model: "anthropic:claude-haiku-4-5",
  # environment variable holding the provider API key (ADR 008: secrets
  # come from the environment, never from config files)
  api_key_env: "ANTHROPIC_API_KEY"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"