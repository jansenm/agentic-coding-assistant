# Test isolation: ALL tests run against an isolated session-store dir
# (Session.Store persists at every turn boundary; without this, test
# sessions leaked into the user's real ~/.local/state storage — found
# by the user's `mix agent --sessions`).
test_store = Path.join(System.tmp_dir!(), "coding-agent-test-store-#{System.unique_integer()}")

Application.put_env(:coding_agent, :store_dir, test_store)

# tests are LLM-free: a fixed cheap spec satisfies the no-default-model
# rule without touching config.exs (which no longer carries a model)
System.put_env("AGENT_MODEL", "ollama:test-model")

# run-wide XDG isolation: UserConfig reads the REAL global config dir
# (Keymap.load/0 does so on every keypress), so tests raced the user's
# live ~/.config files — a broken live TOML even crashed TUI tests
# mid-keypress. Point XDG at an empty run-scoped dir before any test
# starts; user_config_test overrides further per-test (it is async:false).
test_xdg = Path.join(test_store, "xdg")
File.mkdir_p!(Path.join(test_xdg, "config"))
File.mkdir_p!(Path.join(test_xdg, "data"))
System.put_env("XDG_CONFIG_HOME", Path.join(test_xdg, "config"))
System.put_env("XDG_DATA_HOME", Path.join(test_xdg, "data"))

ExUnit.start()

System.at_exit(fn _status -> File.rm_rf!(test_store) end)
