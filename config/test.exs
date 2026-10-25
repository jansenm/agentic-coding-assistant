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

# Tests must not depend on the host for the PROFILE: ADR 030 makes a
# confining sandbox a session-start precondition, so the suite runs under a
# confining TEST DOUBLE by default, and tests that exercise real bwrap
# select it explicitly. The bwrap BINARY, however, is a hard dependency
# (ADR 030/046): a host without it is unsupported, and `test_helper.exs`
# refuses to start the run rather than let the integration tests report a
# pass they did not check (review P13).
config :coding_agent, sandbox: CodingAgent.TestSandbox.Stub

# The model catalog must not refresh in a test run: a refresh downloads ~11 MB
# from llm_db's release host. `Catalog` then never arms its daily check, and
# the pipeline is exercised directly through `Catalog.Refresh`'s parameterized
# entry points, with local documents and a local fetcher.
config :coding_agent, catalog_refresh: [interval_ms: :never]
