import Config

# Tests never call a live provider; the api_key_env name is arbitrary.

# Tests are silent unless something needs attention: warnings/errors
# still surface (AGENTS.md issues, compaction fallback, persist
# failures); debug/info diagnostics (gate decisions, compaction start)
# do not.
config :logger, level: :warning
