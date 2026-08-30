defmodule CodingAgent.Core.PermissionsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Permissions

  @tmp_root System.tmp_dir!() |> Path.join("agent-perm-#{System.unique_integer()}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  defp write_policy(name, content) do
    path = Path.join(@tmp_root, name)
    File.write!(path, content)
    path
  end

  describe "loading" do
    test "missing files give the default policy" do
      policy = Permissions.load(nil, nil)
      assert policy.entries == %{}
      assert Permissions.default_for("read_file") == :allow
      assert Permissions.default_for("write_file") == :ask
      assert Permissions.default_for("shell") == :ask
    end

    test "parses a valid policy" do
      path =
        write_policy("valid.toml", """
        [tools]
        enabled = ["list_dir", "read_file", "write_file"]

        [permissions.write_file]
        "docs/**" = "allow"
        "secret/**" = "deny"
        """)

      policy = Permissions.load(path, nil)

      assert Permissions.effective(policy, "write_file", "docs/x.md") == :allow
      assert Permissions.effective(policy, "write_file", "secret/x") == :deny
      assert Permissions.effective(policy, "write_file", "lib/x.ex") == :ask
    end

    test "fails closed on invalid TOML" do
      path = write_policy("broken.toml", "this is not [valid toml ===")

      assert_raise ArgumentError, ~r/invalid TOML/, fn ->
        Permissions.load(path, nil)
      end
    end

    test "fails closed on an unknown decision value" do
      path =
        write_policy("badvalue.toml", """
        [permissions.write_file]
        "*" = "sure"
        """)

      assert_raise ArgumentError, ~r/must be "allow", "ask" or "deny"/, fn ->
        Permissions.load(path, nil)
      end
    end

    test "fails closed when [tools] enabled is not a list" do
      path =
        write_policy("badtools.toml", """
        [tools]
        enabled = "everything"
        """)

      assert_raise ArgumentError, ~r/must be an array/, fn ->
        Permissions.load(path, nil)
      end
    end
  end

  describe "layer merging (most restrictive wins)" do
    test "repo tighter than user is kept, repo looser than user is ignored (non-elevation)" do
      user =
        write_policy("user.toml", """
        [permissions.write_file]
        "docs/**" = "ask"
        "lib/**" = "deny"
        """)

      repo =
        write_policy("repo.toml", """
        [permissions.write_file]
        "docs/**" = "allow"
        "lib/**" = "allow"
        """)

      policy = Permissions.load(user, repo)

      # user said ask, repo said allow -> ask (repo cannot elevate)
      assert Permissions.effective(policy, "write_file", "docs/x.md") == :ask
      # user said deny, repo said allow -> deny
      assert Permissions.effective(policy, "write_file", "lib/x.ex") == :deny
    end

    test "repo can tighten: ask -> deny" do
      user =
        write_policy("u2.toml", """
        [permissions.shell]
        "*" = "ask"
        """)

      repo =
        write_policy("r2.toml", """
        [permissions.shell]
        "*" = "deny"
        """)

      policy = Permissions.load(user, repo)
      assert Permissions.effective(policy, "shell", "anything") == :deny
    end
  end

  describe "pattern matching" do
    setup do
      path =
        write_policy("patterns.toml", """
        [permissions.write_file]
        "*.md" = "allow"
        "docs/**" = "allow"
        "docs/private/**" = "deny"
        "**/*.exs" = "ask"
        """)

      %{policy: Permissions.load(path, nil)}
    end

    test "single-segment glob does not cross directories", %{policy: policy} do
      assert Permissions.effective(policy, "write_file", "README.md") == :allow
      assert Permissions.effective(policy, "write_file", "sub/README.md") == :ask
    end

    test "double glob crosses directories", %{policy: policy} do
      assert Permissions.effective(policy, "write_file", "docs/guide/intro.md") == :allow
    end

    test "most specific wins over broader allow", %{policy: policy} do
      assert Permissions.effective(policy, "write_file", "docs/private/x.md") == :deny
    end

    test "tie in specificity resolves to the more restrictive", %{policy: policy} do
      # "docs/**" (allow, 2 segments) vs "**/*.exs" (ask, 2 segments) on docs/a.exs
      assert Permissions.effective(policy, "write_file", "docs/a.exs") == :ask
    end

    test "no match falls back to class default", %{policy: policy} do
      assert Permissions.effective(policy, "write_file", "src/a.ex") == :ask
      assert Permissions.effective(policy, "read_file", "src/a.ex") == :allow
    end
  end

  describe "effective/4 role parameter" do
    test "ignores role for now (only default exists in 2b)" do
      policy = Permissions.load(nil, nil)
      assert Permissions.effective(policy, "write_file", "x", "default") == :ask
      assert Permissions.effective(policy, "write_file", "x", "future-role") == :ask
    end
  end
end
