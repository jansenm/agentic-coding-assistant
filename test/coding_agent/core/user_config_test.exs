defmodule CodingAgent.Core.UserConfigTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.UserConfig

  @tmp_root System.tmp_dir!() |> Path.join("ucfg-#{System.unique_integer()}")

  setup do
    File.mkdir_p!(@tmp_root)
    # isolate XDG dirs
    cfg_dir = Path.join(@tmp_root, "home/.config/coding-agent")
    data_dir = Path.join(@tmp_root, "home/.local/share/coding-agent")
    File.mkdir_p!(cfg_dir)
    File.mkdir_p!(data_dir)

    System.put_env("XDG_CONFIG_HOME", Path.join(@tmp_root, "home/.config"))
    System.put_env("XDG_DATA_HOME", Path.join(@tmp_root, "home/.local/share"))

    on_exit(fn ->
      # restore the run-wide seed, never delete: a delete here races
      # async:true files still reading the env (VM-global state). The
      # store is a DB file; its parent is the run-scoped root.
      store_root = Path.dirname(Application.fetch_env!(:coding_agent, :store_path))
      System.put_env("XDG_CONFIG_HOME", Path.join(store_root, "xdg/config"))
      System.put_env("XDG_DATA_HOME", Path.join(store_root, "xdg/data"))
      File.rm_rf!(@tmp_root)
    end)

    %{cfg_dir: cfg_dir, data_dir: data_dir}
  end

  test "missing user files degrade to shipped defaults" do
    cfg = UserConfig.load(nil)
    # layer 0 always provides provider defaults; the user contributed nothing
    assert cfg.config["model"] == nil
    assert cfg.ui == %{}
  end

  test "global config.toml loads; project overlays it" do
    File.write!(Path.join(global_dir(), "config.toml"), """
    model = "ollama:glm-5.3-flash:cloud"
    compaction_trigger_tokens = 180_000
    """)

    File.mkdir_p!(project_dir())

    File.write!(Path.join(project_dir(), "config.toml"), """
    model = "ollama:qwen3:14b"
    """)

    cfg = UserConfig.load(@tmp_root)
    assert cfg.config["model"] == "ollama:qwen3:14b"
    # untouched keys survive the overlay
    assert cfg.config["compaction_trigger_tokens"] == 180_000

    # nil scope: globals only
    assert UserConfig.load(nil).config["model"] == "ollama:glm-5.3-flash:cloud"
  end

  test "ui.toml [keys] reaches Keymap.load" do
    File.write!(Path.join(global_dir(), "ui.toml"), """
    [keys]
    toggle_tool_output = "ctrl-y"
    """)

    km = CodingAgent.UI.Keymap.load()
    assert km.toggle_tool_output == [%{key: :ctrl_y, mod: :none}]
  end

  test "credential: env wins over auth.toml; absent -> :none" do
    File.write!(Path.join(UserConfig.data_dir(), "auth.toml"), """
    [ollama]
    api_key = "file-key"
    """)

    System.put_env("OLLAMA_API_KEY", "env-key")
    assert {:ok, %{api_key: "env-key"}} = UserConfig.credential("ollama")
    System.delete_env("OLLAMA_API_KEY")
    assert {:ok, %{api_key: "file-key"}} = UserConfig.credential("ollama")

    assert {:error, :none} = UserConfig.credential("anthropic")
  end

  test "auth.toml is keys-only: extra fields are not connection info" do
    # connection info comes from config.toml [providers.*]; base_url in
    # auth.toml is simply not read anywhere
    File.write!(Path.join(UserConfig.data_dir(), "auth.toml"), """
    [ollama]
    api_key = "file-key"
    base_url = "should-be-ignored"
    """)

    File.write!(Path.join(global_dir(), "config.toml"), """
    [providers.ollama]
    base_url = "https://ollama.com/v1"
    """)

    cfg = UserConfig.load(nil)
    assert UserConfig.base_url("ollama", cfg.config) == "https://ollama.com/v1"
    assert UserConfig.base_url("anthropic", cfg.config) == nil
  end

  test "auth.toml is never read from a project" do
    File.mkdir_p!(project_dir())

    File.write!(Path.join(project_dir(), "auth.toml"), """
    [ollama]
    api_key = "should-not-load"
    """)

    assert {:error, :none} = UserConfig.credential("ollama")
  end

  test "malformed TOML raises with the file named" do
    File.write!(Path.join(global_dir(), "config.toml"), "model = [unterminated")

    assert_raise(RuntimeError, ~r/config.toml/, fn ->
      UserConfig.load(nil)
    end)
  end

  defp global_dir, do: UserConfig.global_dir()
  defp project_dir, do: UserConfig.project_dir(@tmp_root)

  describe "project config and the no-legacy rule" do
    test "a subdirectory scope reads ONLY its own .coding-agent (no walk up)" do
      repo = Path.join(@tmp_root, "repo")
      sub = Path.join(repo, "pkg/sub")
      File.mkdir_p!(Path.join(repo, ".git"))
      File.mkdir_p!(sub)

      File.mkdir_p!(Path.join(repo, ".coding-agent"))

      File.write!(Path.join([repo, ".coding-agent", "config.toml"]), """
      model = "from-repo-root"
      """)

      # scope_root is the directory the session was started in — the config
      # at the repo root is NOT read from a subdirectory.
      assert UserConfig.project_dir(sub) == Path.join(sub, ".coding-agent")
      refute UserConfig.load(sub).config["model"] == "from-repo-root"
    end

    test "the scope root itself reads its .coding-agent" do
      repo = Path.join(@tmp_root, "repo-self")
      File.mkdir_p!(Path.join(repo, ".git"))
      File.mkdir_p!(Path.join(repo, ".coding-agent"))

      File.write!(Path.join([repo, ".coding-agent", "config.toml"]), """
      model = "from-scope-root"
      """)

      assert UserConfig.load(repo).config["model"] == "from-scope-root"
    end

    test "no enclosing repo: project_dir stays at the scope root" do
      plain = Path.join(@tmp_root, "plain/nested")
      File.mkdir_p!(plain)
      assert UserConfig.project_dir(plain) == Path.join(plain, ".coding-agent")
    end

    test "the pre-ADR-014 agent-permissions.toml is NOT read" do
      # Unreleased software carries no legacy (AGENTS.md): a policy file at
      # the old scope-root path must be ignored, not silently honoured.
      root = Path.join(@tmp_root, "legacy")
      File.mkdir_p!(root)

      File.write!(Path.join(root, "agent-permissions.toml"), """
      [tools]
      enabled = ["read_file", "write_file"]

      [permissions.write_file]
      "**" = "allow"
      """)

      policy =
        root
        |> UserConfig.load()
        |> Map.fetch!(:permissions)

      assert CodingAgent.Core.Permissions.enabled(policy) == :default
    end
  end

  test "layer 0: shipped provider defaults reach the merged config" do
    # no user files written — the shipped defaults alone provide entries
    cfg = UserConfig.load(nil)
    assert cfg.config["providers"]["ollama"]["discover"] == "ollama"

    assert cfg.config["providers"]["ollama_cloud"]["base_url"] ==
             "https://ollama.com/v1"
  end

  test "layer 0: user config overrides a single shipped provider without shadowing the rest" do
    File.write!(Path.join(global_dir(), "config.toml"), """
    [providers.ollama]
    discover = "openai"
    """)

    cfg = UserConfig.load(nil)
    # overridden
    assert cfg.config["providers"]["ollama"]["discover"] == "openai"
    # shipped sibling survives
    assert cfg.config["providers"]["ollama_cloud"]["base_url"] == "https://ollama.com/v1"
  end

  test "provider registry: native fallback for unlisted providers" do
    # no [providers.ollama] table -> native :ollama provider, string spec
    assert {:ok, "ollama:qwen3:14b"} =
             CodingAgent.Core.Providers.model_input("ollama", "qwen3:14b", %{})
  end

  test "provider registry: indirection builds the model map" do
    cfg = %{
      "providers" => %{
        "ollama_cloud" => %{
          "provider" => "openai",
          "base_url" => "https://ollama.com/v1",
          "backend" => "ollama"
        }
      }
    }

    assert {:ok, %CodingAgent.Core.Providers{} = p} =
             CodingAgent.Core.Providers.resolve("ollama_cloud", cfg)

    assert p.req_provider == :openai
    assert p.base_url == "https://ollama.com/v1"

    assert {:ok, %{provider: :openai, id: "gpt-oss:120b"} = mi} =
             CodingAgent.Core.Providers.model_input("ollama_cloud", "gpt-oss:120b", cfg)

    assert mi.base_url == "https://ollama.com/v1"
    assert mi.extra == %{openai_compatible_backend: :ollama}
  end

  test "provider registry: unknown indirection target fails closed" do
    cfg = %{"providers" => %{"bad" => %{"provider" => "nonexistent_xyz"}}}

    assert {:error, {:bad_entry, msg}} =
             CodingAgent.Core.Providers.resolve("bad", cfg)

    assert msg =~ "nonexistent_xyz"
  end

  test "provider registry: native name that req_llm does not know fails" do
    assert {:error, {:bad_entry, msg}} =
             CodingAgent.Core.Providers.resolve("definitely_not_a_provider", %{})

    assert msg =~ "definitely_not_a_provider"
  end
end
