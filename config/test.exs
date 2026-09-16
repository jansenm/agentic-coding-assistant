import Config

# Tests never call a live provider; the api_key_env name is arbitrary.

# Tests are silent unless something needs attention: warnings/errors
# still surface (AGENTS.md issues, compaction fallback, persist
# failures); debug/info diagnostics (gate decisions, compaction start)
# do not.
config :logger, level: :warning

# Tests never own a real tty: every TUI mount would otherwise park the
# BEAM's terminal reader and wait out the 1 s handshake (LocalInput.detach
# has no reader to ack under ExUnit), adding ~1 s to every test that
# starts more than one TUI. Tests inject events directly, so the handoff
# is pure dead time here.
config :ex_ratatui, detach_local_input: false
