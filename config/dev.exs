import Config

# The API key is read from the environment at runtime (ADR 008);
# never committed. dotenvy loads a local .env in development.

config :coding_agent, api_key_env: "ANTHROPIC_API_KEY"