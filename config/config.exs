# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

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
# git-write escalations prompting.

# Credentials are NOT configured here: secrets come from the environment
# (ADR 008), and Request resolves them per provider as `<NAME>_API_KEY`
# via UserConfig.credential/1, then auth.toml. Do not add an
# `api_key_env` key — nothing reads it; the provider name is the source
# of the env var name.

# Cloud ollama models are not in req_llm's catalog; suppress the
# unverified-model warning.
config :req_llm, warn_unverified_models: false

# ex_ratatui's precompiled v0.13.1 NIF crashes (SIGSEGV through a null
# pointer inside the render NIF; four coredumps, ADR 035). Build the NIF
# from source instead. This needs `:rustler` declared as an explicit dep
# (see mix.exs) and a Rust toolchain (cargo/rustc). Delete this line to
# fall back to the precompiled artifact once a fixed release lands.
config :rustler_precompiled, :force_build, ex_ratatui: true

# Override the crate's `[profile.release]` (fat LTO + codegen-units=1,
# new in 0.13.1 and the prime suspect for the corruption) with a
# conservative profile. `rustler` forwards these as cargo environment
# variables; the crate's own Cargo.toml still sets `strip`.
config :ex_ratatui, ExRatatui.Native,
  env: [
    {"CARGO_PROFILE_RELEASE_LTO", "false"},
    {"CARGO_PROFILE_RELEASE_CODEGEN_UNITS", "16"}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
