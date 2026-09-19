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
      store = Application.fetch_env!(:coding_agent, :store_dir)
      System.put_env("XDG_CONFIG_HOME", Path.join(store, "xdg/config"))
      System.put_env("XDG_DATA_HOME", Path.join(store, "xdg/data"))
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
    test "store_dir honours the :store_dir override; state_dir is its parent" do
      override = Path.join(@tmp_root, "sessions")
      prev = Application.get_env(:coding_agent, :store_dir)
      on_exit(fn -> Application.put_env(:coding_agent, :store_dir, prev) end)

      Application.put_env(:coding_agent, :store_dir, override)
      assert Config.store_dir() == override
      assert Config.state_dir() == @tmp_root
    end
  end

  describe "runtime knobs" do
    test "defaults are defined here, not duplicated in config.exs" do
      assert Config.max_tool_rounds() == 100
      assert Config.context_window_tokens() == 500_000
      assert Config.compaction_trigger_tokens() == 180_000
      assert Config.compaction_wall_clock_ms() == 300_000
      assert Config.compaction_inactivity_ms() == 120_000
    end

    test "the no-model message names the user config path" do
      assert Config.no_model_message() =~ UserConfig.global_dir()
      assert Config.no_model_message() =~ "AGENT_MODEL"
    end
  end
end
