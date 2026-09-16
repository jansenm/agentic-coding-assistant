import Config

# CodingAgent configuration (ADR 008): collect knobs here while the
# application grows; secrets come from the environment, never this file.

config :coding_agent,
  # No default model in code (user decision: models are dynamic; the
  # default comes from ~/.config/coding-agent/config.toml `model =`
  # or the AGENT_MODEL env override). Missing default fails with a
  # message naming the config file.
  # context window of the configured model, in tokens (sidebar %).
  context_window_tokens: 500_000,
  # Compaction trigger in ABSOLUTE tokens (default 180k, learned from
  # opencode: its users trust an auto-compact around ~180k; a big
  # window makes %-of-window compaction far too late — the user's
  # GLM sessions grew past 300k before compaction and burned quota at
  # unheard speeds). Visible in the sidebar; predictable by design.
  compaction_trigger_tokens: 180_000,
  # Tool-round guard PER TURN (catches a single runaway loop, not
  # normal work). GLM does one small grep per round — a review turn
  # burned 25 rounds live and died mid-work; the default is now 100.
  # Configurable: :max_tool_rounds in config.exs or a user config
  # override, so heavyweight tasks can turn it up.
  max_tool_rounds: 100

# Credentials are NOT configured here: secrets come from the environment
# (ADR 008), and Request resolves them per provider as `<NAME>_API_KEY`
# via UserConfig.credential/1, then auth.toml. The old `api_key_env:
# "ANTHROPIC_API_KEY"` key was read by nobody — it sat under a comment
# about cloud ollama and misled (codereview docs drift).
#
# Cloud ollama models are not in req_llm's catalog; suppress the
# unverified-model warning.
config :req_llm, warn_unverified_models: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
