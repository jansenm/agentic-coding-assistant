defmodule CodingAgent.Core.AgentTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Agent
  alias CodingAgent.Core.Agent.Frontmatter
  alias CodingAgent.Core.Permissions

  @tmp_root System.tmp_dir!() |> Path.join("agent-defs-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  defp write_agent(dir, filename, content) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), content)
  end

  describe "Frontmatter.parse/2" do
    test "parses the standard fields and body" do
      {:ok, fm} =
        Frontmatter.parse("""
        ---
        name: reviewer
        description: Reviews code
        mode: subagent
        model: ollama:glm
        tools: read_file, grep, glob
        temperature: 0.2
        maxTurns: 15
        permission:
          edit: deny
          shell:
            "*": ask
            "git diff": allow
        ---
        You are a reviewer.
        """)

      assert fm.name == "reviewer"
      assert fm.description == "Reviews code"
      assert fm.mode == "subagent"
      assert fm.model == "ollama:glm"
      assert fm.tools == ["read_file", "grep", "glob"]
      assert fm.temperature == 0.2
      assert fm.max_turns == 15
      assert fm.permission["edit"] == "deny"
      assert fm.permission["shell"]["git diff"] == "allow"
      assert String.trim(fm.body) == "You are a reviewer."
    end

    test "a YAML list for tools works too" do
      {:ok, fm} =
        Frontmatter.parse("""
        ---
        description: d
        tools:
          - read_file
          - grep
        ---
        body
        """)

      assert fm.tools == ["read_file", "grep"]
    end

    test "rejects a file without frontmatter" do
      assert {:error, msg} = Frontmatter.parse("just documentation\n", "doc.md")
      assert msg =~ "no YAML frontmatter"
    end

    test "rejects unclosed frontmatter" do
      assert {:error, msg} = Frontmatter.parse("---\nname: x\n", "x.md")
      assert msg =~ "never closed"
    end

    test "rejects malformed YAML" do
      assert {:error, msg} = Frontmatter.parse("---\nname: [unclosed\n---\nbody\n", "x.md")
      assert msg =~ "x.md"
    end

    test "rejects the erlang fun tag (no code execution)" do
      content = """
      ---
      name: evil
      description: !!fun "os:cmd(\\"touch /tmp/opencode/PWNED-AGENT\\")"
      ---
      body
      """

      assert {:error, _} = Frontmatter.parse(content, "evil.md")
      refute File.exists?("/tmp/opencode/PWNED-AGENT")
    end

    test "rejects frontmatter larger than the cap" do
      big = String.duplicate("a", 70_000)
      assert {:error, msg} = Frontmatter.parse("---\ndescription: #{big}\n---\nbody\n", "big.md")
      assert msg =~ "frontmatter is"
    end

    test "hidden defaults false and parses true" do
      {:ok, fm} = Frontmatter.parse("---\ndescription: d\n---\nbody\n")
      refute fm.hidden

      {:ok, fm2} = Frontmatter.parse("---\ndescription: d\nhidden: true\n---\nbody\n")
      assert fm2.hidden
    end
  end

  describe "Agent.validate/2" do
    test "description is required" do
      assert {:error, msg} = Agent.validate(%Frontmatter{description: nil}, "x.md")
      assert msg =~ "description"

      assert {:error, _} = Agent.validate(%Frontmatter{description: "  "}, "x.md")
    end

    test "mode must be known" do
      fm = %Frontmatter{description: "d", mode: "bogus"}
      assert {:error, msg} = Agent.validate(fm, "x.md")
      assert msg =~ "invalid `mode`"
    end

    test "permission decisions must be allow/ask/deny" do
      fm = %Frontmatter{description: "d", permission: %{"edit" => "maybe"}}
      assert {:error, msg} = Agent.validate(fm, "x.md")
      assert msg =~ "allow, ask or deny"

      fm2 = %Frontmatter{description: "d", permission: %{"shell" => %{"*" => "nope"}}}
      assert {:error, _} = Agent.validate(fm2, "x.md")
    end

    test "a valid definition passes" do
      fm = %Frontmatter{description: "d", mode: "subagent", permission: %{"edit" => "deny"}}
      assert :ok = Agent.validate(fm, "x.md")
    end

    test "`shell: read_only` is valid" do
      fm = %Frontmatter{description: "d", permission: %{"shell" => "read_only"}}
      assert :ok = Agent.validate(fm, "x.md")
    end

    test "`read_only` on a non-shell tool is rejected" do
      fm = %Frontmatter{description: "d", permission: %{"edit" => "read_only"}}
      assert {:error, msg} = Agent.validate(fm, "x.md")
      assert msg =~ "only valid on the shell key"
    end
  end

  describe "Agent.load/1 layering" do
    test "shipped definitions include build, plan and explore" do
      {:ok, agents} = Agent.load(nil)
      names = Enum.map(agents, & &1.name)
      assert "build" in names
      assert "plan" in names
      assert "explore" in names
    end

    test "explore is a delegatable, read-only, model-less subagent (ADR 017/042)" do
      {:ok, agents} = Agent.load(nil)
      explore = Enum.find(agents, &(&1.name == "explore"))

      assert explore.mode == :subagent
      refute Agent.selectable?(explore)
      assert explore.model == nil
      assert "edit" in explore.disallowed_tools
      assert "write_file" in explore.disallowed_tools
      assert "git" in explore.disallowed_tools
      assert explore.permission["shell"] == "read_only"
    end

    test "project layer overrides user layer by name" do
      user = Path.join(@tmp_root, "user-agents")
      write_agent(user, "dup.md", "---\ndescription: user version\n---\nuser body\n")

      project = Agent.project_dir(@tmp_root)
      write_agent(project, "dup.md", "---\ndescription: project version\n---\nproject body\n")

      # load_layer directly so the test does not depend on the real user dir
      {u, []} = Agent.load_layer(user)
      {p, []} = Agent.load_layer(project)
      merged = Map.merge(u, p)

      assert merged["dup"].description == "project version"
      assert String.trim(merged["dup"].prompt) == "project body"
    end

    test "duplicate names in one layer are an error" do
      dir = Path.join(@tmp_root, "dupes")
      write_agent(dir, "a.md", "---\nname: same\ndescription: d\n---\nbody a\n")
      write_agent(dir, "b.md", "---\nname: same\ndescription: d\n---\nbody b\n")

      {_found, errors} = Agent.load_layer(dir)
      assert length(errors) == 1
      assert hd(errors) =~ "duplicate agent name"
    end

    test "a missing directory is fine" do
      assert {%{}, []} = Agent.load_layer(Path.join(@tmp_root, "nope"))
    end

    test "aggregates every error instead of stopping at the first" do
      dir = Path.join(@tmp_root, "broken")
      write_agent(dir, "one.md", "no frontmatter\n")
      write_agent(dir, "two.md", "---\ndescription: [bad\n---\nbody\n")

      write_agent(
        dir,
        "three.md",
        "---\nname: nod\ndescription: d\npermission:\n  edit: maybe\n---\nbody\n"
      )

      {_found, errors} = Agent.load_layer(dir)
      assert length(errors) == 3
      assert Enum.any?(errors, &(&1 =~ "no YAML frontmatter"))
      assert Enum.any?(errors, &(&1 =~ "allow, ask or deny"))
    end

    test "the name field wins over the file name" do
      dir = Path.join(@tmp_root, "naming")
      write_agent(dir, "file-name.md", "---\nname: field-name\ndescription: d\n---\nbody\n")

      {found, []} = Agent.load_layer(dir)
      assert Map.has_key?(found, "field-name")
      refute Map.has_key?(found, "file-name")
    end

    test "the file name is the fallback when name is absent" do
      dir = Path.join(@tmp_root, "naming2")
      write_agent(dir, "fallback.md", "---\ndescription: d\n---\nbody\n")

      {found, []} = Agent.load_layer(dir)
      assert Map.has_key?(found, "fallback")
    end

    test "a definition with an empty prompt is still valid (framework prompt only)" do
      dir = Path.join(@tmp_root, "emptyprompt")
      write_agent(dir, "empty.md", "---\ndescription: d\n---\n")

      {found, []} = Agent.load_layer(dir)
      assert String.trim(found["empty"].prompt) == ""
    end
  end

  describe "canonical_tool/1" do
    test "maps standard names to ours" do
      assert Agent.canonical_tool("bash") == "shell"
      assert Agent.canonical_tool("read") == "read_file"
      assert Agent.canonical_tool("write") == "write_file"
      assert Agent.canonical_tool("list") == "list_dir"
    end

    test "passes unknown names through" do
      assert Agent.canonical_tool("grep") == "grep"
      assert Agent.canonical_tool("custom_tool") == "custom_tool"
    end
  end

  describe "selectable?/1 (ADR 029)" do
    defp agent(mode, hidden \\ false) do
      %Agent{name: "a", prompt: "p", source: "t", mode: mode, hidden: hidden}
    end

    test "primary and all are selectable; subagent is not" do
      assert Agent.selectable?(agent(:primary))
      assert Agent.selectable?(agent(:all))
      refute Agent.selectable?(agent(:subagent))
    end

    test "a hidden primary is not selectable (the @ menu must not offer it)" do
      refute Agent.selectable?(agent(:primary, true))
      refute Agent.selectable?(agent(:all, true))
    end
  end

  describe "Permissions.apply_agent/2 (layer 4)" do
    test "the definition's deny cannot be overridden by allow" do
      policy = Permissions.load(nil, nil)

      agent = %{
        permission: %{"edit" => "deny"},
        tools: nil,
        disallowed_tools: nil
      }

      applied = Permissions.apply_agent(policy, agent)
      assert Permissions.effective(applied, "edit", "a.ex", "default") == :deny
    end

    test "a definition cannot grant what the policy asks" do
      toml = "[permissions.edit]\n\"*\" = \"ask\"\n"
      path = Path.join(@tmp_root, "ask.toml")
      File.write!(path, toml)
      policy = Permissions.load(nil, path)

      agent = %{permission: %{"edit" => "allow"}, tools: nil, disallowed_tools: nil}
      applied = Permissions.apply_agent(policy, agent)

      # most restrictive wins: ask beats the definition's allow
      assert Permissions.effective(applied, "edit", "a.ex", "default") == :ask
    end

    test "permission entries accept a bare decision and a glob table" do
      policy = Permissions.load(nil, nil)

      agent = %{
        permission: %{"shell" => %{"*" => "deny", "git status" => "allow"}},
        tools: nil,
        disallowed_tools: nil
      }

      applied = Permissions.apply_agent(policy, agent)
      assert Permissions.effective(applied, "shell", "", "default") == :deny
    end

    test "tools allow-list narrows the enabled set" do
      policy = Permissions.load(nil, nil)
      assert Permissions.enabled(policy) == :default

      agent = %{permission: %{}, tools: ["read_file", "grep"], disallowed_tools: nil}
      applied = Permissions.apply_agent(policy, agent)

      assert Enum.sort(Permissions.enabled(applied)) == ["grep", "read_file"]
    end

    test "tools allow-list intersects rather than replaces" do
      toml = "[tools]\nenabled = [\"read_file\", \"grep\", \"shell\"]\n"
      path = Path.join(@tmp_root, "en.toml")
      File.write!(path, toml)
      policy = Permissions.load(nil, path)
      assert Enum.sort(Permissions.enabled(policy)) == ["grep", "read_file", "shell"]

      agent = %{permission: %{}, tools: ["read_file", "shell", "git"], disallowed_tools: nil}
      applied = Permissions.apply_agent(policy, agent)

      # intersection: git is dropped, grep is dropped
      assert Enum.sort(Permissions.enabled(applied)) == ["read_file", "shell"]
    end

    test "disallowedTools is exposed via disabled/1" do
      policy = Permissions.load(nil, nil)
      agent = %{permission: %{}, tools: nil, disallowed_tools: ["edit", "shell"]}
      applied = Permissions.apply_agent(policy, agent)

      assert Enum.sort(Permissions.disabled(applied)) == ["edit", "shell"]
    end

    test "standard tool aliases are canonicalized" do
      policy = Permissions.load(nil, nil)
      agent = %{permission: %{"bash" => "deny"}, tools: nil, disallowed_tools: ["write"]}
      applied = Permissions.apply_agent(policy, agent)

      assert Permissions.effective(applied, "shell", "", "default") == :deny
      assert Permissions.disabled(applied) == ["write_file"]
    end

    test "a nil agent leaves the policy untouched" do
      policy = Permissions.load(nil, nil)
      assert Permissions.apply_agent(policy, nil) == policy
    end
  end
end
