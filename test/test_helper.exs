# Test isolation: ALL tests run against an isolated session-store dir
# (Session.Store persists at every turn boundary; without this, test
# sessions leaked into the user's real ~/.local/state storage — found
# by the user's `mix agent --sessions`).
test_store = Path.join(System.tmp_dir!(), "coding-agent-test-store-#{System.unique_integer()}")

Application.put_env(:coding_agent, :store_dir, test_store)

# tests are LLM-free: a fixed cheap spec satisfies the no-default-model
# rule without touching config.exs (which no longer carries a model)
System.put_env("AGENT_MODEL", "ollama:test-model")
ExUnit.start()

System.at_exit(fn _status -> File.rm_rf!(test_store) end)
