# Test isolation: ALL tests run against an isolated session-store dir
# (Session.Store persists at every turn boundary; without this, test
# sessions leaked into the user's real ~/.local/state storage — found
# by the user's `mix agent --sessions`).
test_store = Path.join(System.tmp_dir!(), "coding-agent-test-store-#{System.unique_integer()}")

Application.put_env(:coding_agent, :store_dir, test_store)
ExUnit.start()

System.at_exit(fn _status -> File.rm_rf!(test_store) end)
