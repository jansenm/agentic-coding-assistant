# One tmp root per RUN. The session scratch, the checkpoint's temp index
# and the summarizer's spill all live under <tmp>/coding-agent/<session-id>,
# a path keyed by the id alone — shared between processes by construction.
# Two `mix test` runs at the same time (this repo has two worktrees, and
# both agents run the suite) collide on git's index lock there:
# "Unable to create '<scratch>/checkpoint-index.lock': File exists".
# A run-scoped TMPDIR makes that class unreachable.
run_tmp = Path.join(System.tmp_dir!(), "coding-agent-run-#{System.unique_integer([:positive])}")
File.mkdir_p!(run_tmp)
System.put_env("TMPDIR", run_tmp)

# Test isolation: ALL tests run against an isolated session store
# (Session.Store persists at every turn boundary; without this, test
# sessions leaked into the user's real ~/.local/state storage — found
# by the user's session listing). The store is now one SQLite DB FILE
# (ADR 020); the test root is a directory that holds it plus the XDG dirs.
test_root = Path.join(run_tmp, "store")
test_store = Path.join(test_root, "store.db")

Application.put_env(:coding_agent, :store_path, test_store)

# tests are LLM-free: a fixed cheap spec satisfies the no-default-model
# rule without touching config.exs (which no longer carries a model)
System.put_env("AGENT_MODEL", "ollama:test-model")

# run-wide XDG isolation: UserConfig reads the REAL global config dir
# (Keymap.load/0 does so on every keypress), so tests raced the user's
# live ~/.config files — a broken live TOML even crashed TUI tests
# mid-keypress. Point XDG at an empty run-scoped dir before any test
# starts; user_config_test overrides further per-test (it is async:false).
test_xdg = Path.join(test_root, "xdg")
File.mkdir_p!(Path.join(test_xdg, "config"))
File.mkdir_p!(Path.join(test_xdg, "data"))
System.put_env("XDG_CONFIG_HOME", Path.join(test_xdg, "config"))
System.put_env("XDG_DATA_HOME", Path.join(test_xdg, "data"))

ExUnit.start()

System.at_exit(fn _status -> File.rm_rf!(run_tmp) end)
