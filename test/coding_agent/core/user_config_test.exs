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
      System.delete_env("XDG_CONFIG_HOME")
      System.delete_env("XDG_DATA_HOME")
      File.rm_rf!(@tmp_root)
    end)

    %{cfg_dir: cfg_dir, data_dir: data_dir}
  end

  test "missing files degrade to empty defaults" do
    cfg = UserConfig.load(nil)
    assert cfg.config == %{}
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
    cloud_via_openai = true
    """)

    cfg = UserConfig.load(nil)
    assert UserConfig.base_url("ollama", cfg.config) == "https://ollama.com/v1"
    assert UserConfig.cloud_via_openai?("ollama", cfg.config) == true
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
  defp project_dir, do: UserConfig.project_dir_for_test(@tmp_root)
end
