import Config

# CodingAgent configuration (ADR 008): collect knobs here while the
# application grows; secrets come from the environment, never this file.

# Runtime knobs (context window, compaction trigger/budgets, tool-round
# guard, sandbox, state dir) have their SINGLE default in
# `CodingAgent.Core.Config` (and `Sandbox` for the sandbox choice) — do
# not repeat the literals here. Override a key here only when a build
# genuinely needs a different value; the module default applies when the
# key is absent.
#
# No default model in code (user decision: models are dynamic; the
# default comes from ~/.config/coding-agent/config.toml `model =`
# or the AGENT_MODEL env override). Missing default fails with a
# message naming the config file.
#
# Process confinement (ADR 015/030): Bwrap is the default and a session
# REQUIRES confinement — where bwrap cannot run (no binary, or
# unprivileged user namespaces disabled by host hardening) the app logs a
# warning at startup and every session start refuses with the diagnostic.
# shell/git run allow-by-default inside the profile, with only network and
# git-write escalations prompting. `Sandbox.None` exists as a test seam
# and an explicit opt-out; selecting it means the session runs unconfined.

# Credentials are NOT configured here: secrets come from the environment
# (ADR 008), and Request resolves them per provider as `<NAME>_API_KEY`
# via UserConfig.credential/1, then auth.toml. Do not add an
# `api_key_env` key — nothing reads it; the provider name is the source
# of the env var name.

# Cloud ollama models are not in req_llm's catalog; suppress the
# unverified-model warning.
config :req_llm, warn_unverified_models: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
