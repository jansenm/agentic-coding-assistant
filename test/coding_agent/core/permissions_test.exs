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
      assert Permissions.default_for("shell") == :ask

      # ADR 010 amendment 2026-09-15: edit AND write_file are
      # allow-by-class (contained, VCS-reviewable); shell is not
      assert Permissions.default_for("edit") == :allow
      assert Permissions.default_for("write_file") == :allow
      assert Permissions.default_for("webfetch") == :ask
    end

    test "a write allow default is overridable per path (class default is only the floor)" do
      path =
        write_policy("write-ask.toml", """
        [permissions.write_file]
        "config/**" = "ask"
        """)

      policy = Permissions.load(nil, path)

      assert Permissions.effective(policy, "write_file", "config/prod.exs") == :ask
      # outside the entry: back to the class default
      assert Permissions.effective(policy, "write_file", "lib/other.ex") == :allow
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
      # outside the entries: the class default (allow since the
      # 2026-09-15 amendment)
      assert Permissions.effective(policy, "write_file", "lib/x.ex") == :allow
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

  describe "shell read-only mode" do
    test "defaults to read-write" do
      assert Permissions.shell_mode(Permissions.load(nil, nil)) == :rw
    end

    test "`shell = \"read_only\"` means allow + a read-only root" do
      path =
        write_policy("shell-ro.toml", """
        [permissions]
        shell = "read_only"
        """)

      policy = Permissions.load(nil, path)

      assert Permissions.shell_mode(policy) == :ro
      # and it IS allowed (not ask): the RO confinement is the boundary
      assert Permissions.effective(policy, "shell", "anything") == :allow
    end

    test "`read_only` on any other tool is an error" do
      path =
        write_policy("ro-wrong-tool.toml", """
        [permissions]
        edit = "read_only"
        """)

      assert_raise ArgumentError, ~r/only valid on the shell key/, fn ->
        Permissions.load(nil, path)
      end
    end

    test "a :ro layer cannot be widened back to :rw by another layer" do
      ro = write_policy("ro.toml", "[permissions]\nshell = \"read_only\"\n")
      rw = write_policy("rw.toml", "[permissions.shell]\n\"*\" = \"allow\"\n")

      assert Permissions.shell_mode(Permissions.load(nil, ro)) == :ro
      assert Permissions.shell_mode(Permissions.load(rw, ro)) == :ro
      assert Permissions.shell_mode(Permissions.load(ro, rw)) == :ro
    end

    test "an agent definition can set the read-only shell mode" do
      base = Permissions.load(nil, nil)

      assert Permissions.shell_mode(
               Permissions.apply_agent(base, %{permission: %{"shell" => "read_only"}})
             ) == :ro
    end

    test "an agent definition cannot widen a :ro policy back to :rw" do
      ro =
        Permissions.load(nil, write_policy("ro2.toml", "[permissions]\nshell = \"read_only\"\n"))

      # the definition says nothing about shell mode (defaults :rw)
      applied = Permissions.apply_agent(ro, %{tools: ["read_file"]})
      assert Permissions.shell_mode(applied) == :ro

      # even an explicit allow does not widen it
      applied2 = Permissions.apply_agent(ro, %{permission: %{"shell" => "allow"}})
      assert Permissions.shell_mode(applied2) == :ro
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

  describe "[tools] enabled (whitelist, non-elevation)" do
    test "no layer sets it -> :default (the whole registry)" do
      assert Permissions.enabled(Permissions.load(nil, nil)) == :default
    end

    test "a single layer's list is the whitelist" do
      user =
        write_policy("en-user.toml", """
        [tools]
        enabled = ["list_dir", "read_file"]
        """)

      assert Permissions.enabled(Permissions.load(user, nil)) == ["list_dir", "read_file"]
    end

    test "layers intersect: a project layer can only disable more, never re-enable" do
      user =
        write_policy("en-i-user.toml", """
        [tools]
        enabled = ["list_dir", "read_file", "grep"]
        """)

      repo =
        write_policy("en-i-repo.toml", """
        [tools]
        enabled = ["read_file", "grep", "write_file"]
        """)

      # union would be all four (project re-enabling list_dir);
      # intersection is the only non-elevating merge
      assert Permissions.enabled(Permissions.load(user, repo)) == ["grep", "read_file"]
    end

    test "an empty enabled list imposes no restriction (skipped in the merge)" do
      user =
        write_policy("en-empty.toml", """
        [tools]
        enabled = []
        """)

      repo =
        write_policy("en-r.toml", """
        [tools]
        enabled = ["read_file"]
        """)

      assert Permissions.enabled(Permissions.load(user, repo)) == ["read_file"]
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

      # "sub/README.md" matches no entry ("*.md" is per-segment) — but
      # "**/*.exs" does not match either, so this is the class default
      # (allow since the 2026-09-15 amendment), not the :ask entry
      assert Permissions.effective(policy, "write_file", "sub/README.md") == :allow
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
      # both tools' class default is allow (the 2026-09-15 amendment
      # added write_file to the allow class; read_file was always there)
      assert Permissions.effective(policy, "write_file", "src/a.ex") == :allow
      assert Permissions.effective(policy, "read_file", "src/a.ex") == :allow
    end

    test "** matches zero directories" do
      path =
        write_policy("double-star.toml", """
        [permissions.write_file]
        "docs/**/*.ex" = "deny"
        "lib/**/secret.txt" = "deny"
        """)

      policy = Permissions.load(path, nil)

      # the fix: a file DIRECTLY under docs/ must match docs/**/*.ex,
      # not just docs/<subdir>/x.ex — the old per-segment builder
      # wedged "**" between slashes and missed the zero-dir case
      assert Permissions.effective(policy, "write_file", "docs/a.ex") == :deny
      assert Permissions.effective(policy, "write_file", "docs/x/a.ex") == :deny

      # and the same for a literal trailing segment
      assert Permissions.effective(policy, "write_file", "lib/secret.txt") == :deny
      assert Permissions.effective(policy, "write_file", "lib/deep/secret.txt") == :deny
    end

    test "a policy glob and the glob tool agree (one dialect)" do
      alias CodingAgent.Core.GlobMatch

      for {pattern, path} <- [
            {"docs/**/*.ex", "docs/a.ex"},
            {"docs/**/*.ex", "docs/x/a.ex"},
            {"**/*.exs", "a.exs"},
            {"**/*.exs", "x/a.exs"},
            {"a/**/b", "a/b"},
            {"a/**/b", "a/x/b"},
            {"lib/**", "lib/a.ex"}
          ] do
        assert GlobMatch.match?(pattern, path),
               "expected #{pattern} to match #{path}"

        # permission lookup uses the very same matcher
        policy =
          Permissions.load(
            write_policy("g-#{System.unique_integer()}.toml", """
            [permissions.write_file]
            "#{pattern}" = "deny"
            """),
            nil
          )

        assert Permissions.effective(policy, "write_file", path) == :deny,
               "policy and glob must agree on #{pattern} vs #{path}"
      end
    end
  end

  describe "effective/4 role parameter" do
    test "ignores role for now (only default exists in 2b)" do
      policy = Permissions.load(nil, nil)
      assert Permissions.effective(policy, "shell", "x", "default") == :ask
      assert Permissions.effective(policy, "shell", "x", "future-role") == :ask
    end
  end
end
