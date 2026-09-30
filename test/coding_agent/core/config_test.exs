defmodule CodingAgent.Core.ConfigTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Config
  alias CodingAgent.Core.UserConfig

  @tmp_root System.tmp_dir!() |> Path.join("cfg-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(Path.join(@tmp_root, ".coding-agent"))

    System.put_env("XDG_CONFIG_HOME", Path.join(@tmp_root, "home/.config"))
    System.put_env("XDG_DATA_HOME", Path.join(@tmp_root, "home/.local/share"))
    File.mkdir_p!(UserConfig.global_dir())

    on_exit(fn ->
      # restore the run-wide seed, never delete (VM-global state races
      # async tests still reading the env)
      # the store is a DB file; its parent is the run-scoped root
      store_root = Path.dirname(Application.fetch_env!(:coding_agent, :store_path))
      System.put_env("XDG_CONFIG_HOME", Path.join(store_root, "xdg/config"))
      System.put_env("XDG_DATA_HOME", Path.join(store_root, "xdg/data"))
      File.rm_rf!(@tmp_root)
    end)

    :ok
  end

  describe "snapshot/1" do
    test "reads providers, mounts, permissions and agents in one pass" do
      File.write!(Path.join(UserConfig.global_dir(), "config.toml"), """
      model = "ollama:qwen3:14b"
      [providers.custom]
      base_url = "https://example.test/v1"
      [sandbox]
      ro = ["/data"]
      """)

      snap = Config.snapshot(@tmp_root)

      assert snap.root == @tmp_root
      assert snap.config["model"] == "ollama:qwen3:14b"
      assert snap.providers["custom"]["base_url"] == "https://example.test/v1"
      assert "/data" in snap.mounts.ro
      assert %CodingAgent.Core.Permissions{} = snap.permissions
      assert {:ok, agents} = snap.agents
      assert Enum.any?(agents, &(&1.name == "build"))
    end

    test "a project layer overrides the global model" do
      File.write!(Path.join(UserConfig.global_dir(), "config.toml"), ~s(model = "ollama:global"))
      File.write!(Path.join(@tmp_root, ".coding-agent/config.toml"), ~s(model = "ollama:project"))

      assert Config.snapshot(@tmp_root).config["model"] == "ollama:project"
      # nil scope: globals only
      assert Config.snapshot(nil).config["model"] == "ollama:global"
    end

    test "rw mounts never come from the project layer (ADR 015)" do
      File.write!(Path.join(@tmp_root, ".coding-agent/config.toml"), """
      [sandbox]
      rw = ["/should-not-apply"]
      ro = ["/project-ro"]
      """)

      snap = Config.snapshot(@tmp_root)
      refute "/should-not-apply" in snap.mounts.rw
      assert "/project-ro" in snap.mounts.ro
    end
  end

  describe "model/1" do
    test "accepts a snapshot or a scope root; AGENT_MODEL wins" do
      File.write!(Path.join(UserConfig.global_dir(), "config.toml"), ~s(model = "ollama:cfg"))

      prev = System.get_env("AGENT_MODEL")
      on_exit(fn -> if prev, do: System.put_env("AGENT_MODEL", prev) end)
      System.delete_env("AGENT_MODEL")

      assert Config.model(nil) == "ollama:cfg"
      assert Config.model(Config.snapshot(nil)) == "ollama:cfg"

      System.put_env("AGENT_MODEL", "ollama:env")
      assert Config.model(nil) == "ollama:env"
    end
  end

  describe "state paths" do
    test "store_path honours the :store_path override; state_dir is its parent" do
      override = Path.join(@tmp_root, "sessions")
      prev = Application.get_env(:coding_agent, :store_path)
      on_exit(fn -> Application.put_env(:coding_agent, :store_path, prev) end)

      Application.put_env(:coding_agent, :store_path, override)
      assert Config.store_path() == override
      assert Config.state_dir() == @tmp_root
    end
  end

  describe "store selection (ADR 020 R16)" do
    setup do
      # never let a test leave a global :store_path / AGENT_STORE behind
      prev_dir = Application.get_env(:coding_agent, :store_path)
      prev_env = System.get_env("AGENT_STORE")

      on_exit(fn ->
        Application.put_env(:coding_agent, :store_path, prev_dir)

        if prev_env,
          do: System.put_env("AGENT_STORE", prev_env),
          else: System.delete_env("AGENT_STORE")
      end)

      :ok
    end

    test "an absolute path resolves as-is" do
      assert {:ok, "/abs/store"} = Config.resolve_store("/abs/store")
    end

    test "a ~-rooted path expands against HOME" do
      assert {:ok, expanded} = Config.resolve_store("~/mystore")
      assert expanded == Path.join(System.user_home!(), "mystore")
    end

    test "a name resolves through config.toml [stores]" do
      File.write!(Path.join(UserConfig.global_dir(), "config.toml"), """
      [stores]
      work = "/data/work-sessions"
      """)

      assert {:ok, "/data/work-sessions"} = Config.resolve_store("work")
      assert Config.stores()["work"] == "/data/work-sessions"
    end

    test "an unknown name is an error, not a guessed path" do
      assert {:error, {:unknown_store, "nope"}} = Config.resolve_store("nope")
      assert {:error, {:unknown_store, _}} = Config.resolve_store("relative/path")
    end

    test "select_store! sets the :store_path seam so Store.path follows" do
      assert "/abs/loud" = Config.select_store!("/abs/loud")
      assert Application.get_env(:coding_agent, :store_path) == "/abs/loud"
      assert CodingAgent.Core.Session.Store.path() == "/abs/loud"
    end

    test "select_store!(nil) keeps an already-pinned store (no clobber)" do
      Application.put_env(:coding_agent, :store_path, "/pinned/store")
      assert "/pinned/store" = Config.select_store!(nil)
    end

    test "select_store! pins the default when nothing is configured" do
      Application.delete_env(:coding_agent, :store_path)
      System.delete_env("AGENT_STORE")

      path = Config.select_store!(nil)
      assert path == Path.join(Config.state_dir(), "store.db")
      assert Application.get_env(:coding_agent, :store_path) == path
    end

    test "select_store! raises with an actionable message on a bad selector" do
      assert_raise RuntimeError, ~r/unknown_store|resolve session store/, fn ->
        Config.select_store!("definitely-not-a-store")
      end
    end

    test "store_path honours AGENT_STORE (path) when no explicit override is set" do
      Application.delete_env(:coding_agent, :store_path)
      System.put_env("AGENT_STORE", "/env/store")

      assert Config.store_path() == "/env/store"

      # and config.toml `store =` is the next fallback
      System.delete_env("AGENT_STORE")
      File.write!(Path.join(UserConfig.global_dir(), "config.toml"), ~s(store = "/cfg/store"))
      assert Config.store_path() == "/cfg/store"
    end

    test "the :store_path override wins over AGENT_STORE (the test seam is strongest)" do
      System.put_env("AGENT_STORE", "/env/store")
      Application.put_env(:coding_agent, :store_path, "/override/store")

      assert Config.store_path() == "/override/store"
    end
  end

  describe "runtime knobs" do
    test "defaults are defined here, not duplicated in config.exs" do
      assert Config.max_tool_rounds() == 100
      assert Config.context_window(%Config{config: %{}}, nil) == 500_000
      assert Config.compaction_soft_ratio(%Config{config: %{}}) == 0.5
      assert Config.compaction_hard_reserve_tokens(%Config{config: %{}}) == 64_000
      assert Config.compaction_wall_clock_ms() == 300_000
      assert Config.compaction_inactivity_ms() == 120_000
    end

    test "compaction limits derive from the window (ADR 037)" do
      snapshot = %Config{config: %{"context_window" => 400_000}}
      # soft = round(400k * 0.5); hard = 400k - 64k (reserve > the 0.75 floor)
      assert Config.compaction_limits(snapshot, nil) == {400_000, 200_000, 336_000}
    end

    test "compaction hard limit is floored on a window below 4x the reserve (review N1)" do
      # window 50k < reserve 64k: without the floor hard collapsed to 1
      # and a pre-call summarize fired at ~4% utilisation. Floor at 75%.
      snapshot = %Config{config: %{"context_window" => 50_000}}
      assert Config.compaction_limits(snapshot, nil) == {50_000, 25_000, 37_500}
    end

    test "the hard floor keeps the reserve at most a quarter of a small window" do
      # window 200k: window - reserve = 136k < 150k floor, so the floor
      # governs — the absolute reserve is capped at 25% for smaller windows.
      snapshot = %Config{config: %{"context_window" => 200_000}}
      assert Config.compaction_limits(snapshot, nil) == {200_000, 100_000, 150_000}
    end

    test "context_window honours a config.toml value over the catalog/default" do
      snapshot = %Config{config: %{"context_window" => 123_456}}
      assert Config.context_window(snapshot, "ollama:whatever") == 123_456
    end

    test "context_window is configured? only when config.toml pins it" do
      assert Config.context_window_configured?(%Config{config: %{"context_window" => 123_456}})
      refute Config.context_window_configured?(%Config{config: %{}})
    end

    test "max_tool_rounds honours a config.toml value over the default (ADR 025)" do
      snapshot = %Config{config: %{"max_tool_rounds" => 42}}
      assert Config.max_tool_rounds(snapshot) == 42
    end

    test "max_tool_rounds ignores a non-positive config.toml value" do
      snapshot = %Config{config: %{"max_tool_rounds" => 0}}
      assert Config.max_tool_rounds(snapshot) == 100
    end

    test "subagent_concurrency defaults to 3 (Ollama's parallel limit, ADR 018)" do
      assert Config.subagent_concurrency(%Config{config: %{}}) == 3
    end

    test "subagent_concurrency honours a config.toml value over the default" do
      snapshot = %Config{config: %{"subagent_concurrency" => 8}}
      assert Config.subagent_concurrency(snapshot) == 8
    end

    test "subagent_concurrency ignores a non-positive config.toml value" do
      snapshot = %Config{config: %{"subagent_concurrency" => 0}}
      assert Config.subagent_concurrency(snapshot) == 3
    end

    test "provider retries default to 3 and 5000ms" do
      assert Config.provider_retries(%Config{config: %{}}) == 3
      assert Config.provider_retry_delay_ms(%Config{config: %{}}) == 5_000
    end

    test "provider retries honour config.toml over the default" do
      snapshot = %Config{config: %{"provider_retries" => 0, "provider_retry_delay_ms" => 250}}
      assert Config.provider_retries(snapshot) == 0
      assert Config.provider_retry_delay_ms(snapshot) == 250
    end

    test "provider retries ignore a negative config.toml value" do
      snapshot = %Config{config: %{"provider_retries" => -1}}
      assert Config.provider_retries(snapshot) == 3
    end

    test "provider receive timeout defaults to 120000 and honors config.toml" do
      assert Config.provider_receive_timeout_ms(%Config{config: %{}}) == 120_000

      assert Config.provider_receive_timeout_ms(%Config{
               config: %{"provider_receive_timeout_ms" => 300_000}
             }) == 300_000

      # non-positive falls through to the default (a zero-timeout call is never wanted)
      assert Config.provider_receive_timeout_ms(%Config{
               config: %{"provider_receive_timeout_ms" => 0}
             }) == 120_000
    end

    test "checkpoint depth defaults to 1 and honors config.toml" do
      assert Config.checkpoint_depth(%Config{config: %{}}) == 1
      assert Config.checkpoint_depth(%Config{config: %{"checkpoint_depth" => 0}}) == 0
      assert Config.checkpoint_depth(%Config{config: %{"checkpoint_depth" => 5}}) == 5
      # non-positive is allowed (0 disables); only non-integers fall through
      assert Config.checkpoint_depth(%Config{config: %{"checkpoint_depth" => "x"}}) == 1
    end

    test "the no-model message names the user config path" do
      assert Config.no_model_message() =~ UserConfig.global_dir()
      assert Config.no_model_message() =~ "AGENT_MODEL"
    end

    test "reasoning_effort reads a config.toml string as the canonical atom (ADR 029)" do
      snapshot = %Config{config: %{"reasoning_effort" => "high"}}
      assert Config.reasoning_effort(snapshot) == :high
    end

    test "reasoning_effort trims and lowercases, and nil means the provider default" do
      assert Config.reasoning_effort(%Config{config: %{"reasoning_effort" => "  HIGH "}}) == :high
      assert Config.reasoning_effort(%Config{config: %{}}) == nil
    end

    test "reasoning_effort raises on an unknown value instead of silently ignoring it" do
      # a typo that changes nothing is the exact bug this accessor kills:
      # the sidebar used to show the string while req_llm never saw it
      assert_raise RuntimeError, ~r/invalid config.toml `reasoning_effort`/, fn ->
        Config.reasoning_effort(%Config{config: %{"reasoning_effort" => "bogus"}})
      end
    end

    test "reasoning_effort rejects an atom config value outside the canonical set" do
      assert_raise RuntimeError, ~r/must be one of/, fn ->
        Config.reasoning_effort(%Config{config: %{"reasoning_effort" => :bogus}})
      end
    end

    test "reasoning_effort rejects a non-string, non-atom value" do
      assert_raise RuntimeError, ~r/must be one of/, fn ->
        Config.reasoning_effort(%Config{config: %{"reasoning_effort" => 3}})
      end
    end
  end
end
