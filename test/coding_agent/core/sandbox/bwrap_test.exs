defmodule CodingAgent.Core.Sandbox.BwrapTest do
  use ExUnit.Case, async: false

  import CodingAgent.SandboxCase

  alias CodingAgent.Core.Sandbox.Bwrap
  alias CodingAgent.Core.Session.Scratch
  alias CodingAgent.Core.Tools.Shell

  @tmp_root System.tmp_dir!() |> Path.join("agent-bwrap-#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    # NOTE: the argv/3 tests are pure and need no configured sandbox; the
    # integration tests below select Bwrap explicitly via put_sandbox/1
    # (restored on exit, ADR 030).
    {:ok, root: @tmp_root}
  end

  describe "argv/3 (pure)" do
    test "always mounts the root read-only first", %{root: root} do
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root})

      assert Enum.take(argv, 3) == ["--ro-bind", "/", "/"]
      assert triple_in(argv, {"--bind", root, root})
    end

    test "unshares all namespaces and keeps the network off by default", %{root: root} do
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root})

      assert "--unshare-all" in argv
      refute "--share-net" in argv
    end

    test "grants the network only when the profile says so", %{root: root} do
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root, network: true})

      assert "--share-net" in argv
    end

    test "re-binds an existing .git read-only for plain shell", %{root: root} do
      init_git!(root)
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root})
      git = Path.join(root, ".git")

      assert triple_in(argv, {"--ro-bind", git, git})
    end

    test "leaves .git writable when git_write is granted", %{root: root} do
      init_git!(root)
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root, git_write: true})
      git = Path.join(root, ".git")

      assert triple_in(argv, {"--bind", git, git})
    end

    test "binds the scope root read-only when root_ro is set", %{root: root} do
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root, root_ro: true})

      assert triple_in(argv, {"--ro-bind", root, root})
      # and NOT the read-write root bind
      refute triple_in(argv, {"--bind", root, root})
    end

    test "binds the scope root read-write by default", %{root: root} do
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root})

      assert triple_in(argv, {"--bind", root, root})
    end

    test "root_ro keeps .git read-only (and git_write cannot widen it)", %{root: root} do
      init_git!(root)
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root, root_ro: true, git_write: true})
      git = Path.join(root, ".git")

      assert triple_in(argv, {"--ro-bind", root, root})
      assert triple_in(argv, {"--ro-bind", git, git})
      refute triple_in(argv, {"--bind", git, git})
    end

    test "a git worktree binds its gitdir AND common dir read-write (git_write)", %{root: root} do
      # A worktree's `.git` is a gitfile pointing OUTSIDE the scope root;
      # a commit also writes objects/refs in the shared common dir. Both
      # must be bound or git dies on index.lock (found live).
      {wt, common} = init_worktree!(root)
      argv = Bwrap.argv(wt, {:exec, "git", ["commit"]}, %{root: wt, git_write: true})

      assert triple_in(
               argv,
               {"--bind", Path.join(common, ".git/worktrees/wt"),
                Path.join(common, ".git/worktrees/wt")}
             )

      assert triple_in(argv, {"--bind", Path.join(common, ".git"), Path.join(common, ".git")})
    end

    test "a git worktree binds its gitdirs read-only for plain shell", %{root: root} do
      {wt, common} = init_worktree!(root)
      argv = Bwrap.argv(wt, {:shell, "git log"}, %{root: wt})

      assert triple_in(
               argv,
               {"--ro-bind", Path.join(common, ".git/worktrees/wt"),
                Path.join(common, ".git/worktrees/wt")}
             )

      assert triple_in(argv, {"--ro-bind", Path.join(common, ".git"), Path.join(common, ".git")})
    end

    test "hides a directory with an empty tmpfs and a file with /dev/null", %{root: root} do
      dir = Path.join(root, "secret-dir")
      file = Path.join(root, "secret-file")
      File.mkdir_p!(dir)
      File.write!(file, "secret")

      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root, hide: [dir, file]})

      assert triple_in(argv, {"--tmpfs", dir})
      # --dev-bind, not --ro-bind: a ro-bound device is unreadable under
      # the nodev mount of an unprivileged userns (EACCES). Found live by
      # the ADR 030 file-tool integration test.
      assert triple_in(argv, {"--dev-bind", "/dev/null", file})
    end

    test "sets resource caps in the shell prelude", %{root: root} do
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root})
      command = List.last(argv)

      assert command =~ "ulimit -u 512"
      assert command =~ "ulimit -f 4194304"
      assert command =~ "ulimit -t 1800"
      assert command =~ "echo hi"
    end

    test "mounts configured rw paths that exist, skips missing ones", %{root: root} do
      cache = Path.join(root, "cache")
      File.mkdir_p!(cache)
      missing = Path.join(root, "nope")

      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root, rw: [cache, missing]})

      assert triple_in(argv, {"--bind", cache, cache})
      refute triple_in(argv, {"--bind", missing, missing})
    end

    test "mounts configured ro paths that exist", %{root: root} do
      ro = Path.join(root, "readonly")
      File.mkdir_p!(ro)

      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root, ro: [ro]})

      assert triple_in(argv, {"--ro-bind", ro, ro})
    end

    test "scratch tmpfs comes before the scope bind so a scope under /tmp survives", %{root: root} do
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root})

      tmpfs_at = Enum.find_index(argv, &(&1 == "/tmp"))
      bind_at = Enum.find_index(argv, &(&1 == root))

      assert tmpfs_at < bind_at
    end

    test "no session scratch keeps the per-call tmpfs (behaviour unchanged)", %{root: root} do
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root, scratch: nil})

      assert triple_in(argv, {"--tmpfs", "/tmp"})
      assert Enum.member?(argv, "--size")
      refute triple_in(argv, {"--bind", "/tmp", "/tmp"})
    end

    test "a session scratch is bound over /tmp instead of the tmpfs", %{root: root} do
      scratch = Path.join(root, "scratch")
      File.mkdir_p!(scratch)
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root, scratch: scratch})

      assert triple_in(argv, {"--bind", scratch, "/tmp"})
      refute triple_in(argv, {"--tmpfs", "/tmp"})
      refute Enum.member?(argv, "--size")
    end

    test "the prelude exports TMPDIR=/tmp so hardcoded /tmp and $TMPDIR agree", %{root: root} do
      argv = Bwrap.argv(root, {:shell, "echo hi"}, %{root: root})
      command = List.last(argv)

      assert command =~ "export TMPDIR=/tmp;"
    end

    test "wrap/2 creates the session scratch lazily", %{root: root} do
      scratch = Path.join(root, "lazy-scratch")
      refute File.dir?(scratch)

      assert {:ok, _exe, _argv} = Bwrap.wrap({:shell, "true"}, %{root: root, scratch: scratch})
      assert File.dir?(scratch)
      assert File.stat!(scratch).mode |> Bitwise.band(0o777) == 0o700
    end

    test "refuses a missing scope root" do
      missing = Path.join(@tmp_root, "does-not-exist")

      assert {:error, {:no_scope_root, _}} = Bwrap.wrap("echo hi", %{root: missing})
    end
  end

  describe "availability" do
    test "id is :bwrap" do
      assert Bwrap.id() == :bwrap
    end

    test "probe is a boolean and is memoised" do
      first = Bwrap.probe()
      assert is_boolean(first)
      assert Bwrap.probe() == first
    end
  end

  describe "integration (real bwrap)" do
    setup do
      if Bwrap.available?() do
        :ok
      else
        # Missing binary or no unprivileged userns (hardened host): this is
        # the Sandbox.None fallback path, not a failure. Skip.
        {:ok, skip: true}
      end
    end

    test "runs a command confined and sees the scope root", %{root: root} = ctx do
      if ctx[:skip] do
        :ok
      else
        put_sandbox(Bwrap)
        tool = Shell.tool(%{root: root})

        assert {:ok, out} = ReqLLM.Tool.execute(tool, %{"command" => "pwd"})
        assert out =~ root
      end
    end

    test "writes reach the real tree, commits do not", %{root: root} = ctx do
      if ctx[:skip] do
        :ok
      else
        init_git!(root)
        File.write!(Path.join(root, "app.txt"), "v1\n")
        git!(root, ~w(add app.txt))
        git!(root, ~w(commit -m init))

        put_sandbox(Bwrap)
        tool = Shell.tool(%{root: root})

        assert {:ok, out} =
                 ReqLLM.Tool.execute(tool, %{
                   "command" => "echo v2 > app.txt && git commit -am x 2>&1 | tail -1"
                 })

        assert out =~ "Read-only file system"
        assert File.read!(Path.join(root, "app.txt")) == "v2\n"
      end
    end

    test "root and .git cannot be deleted", %{root: root} = ctx do
      if ctx[:skip] do
        :ok
      else
        init_git!(root)
        put_sandbox(Bwrap)
        tool = Shell.tool(%{root: root})

        assert {:ok, _out} = ReqLLM.Tool.execute(tool, %{"command" => "rm -rf .git"})
        assert File.dir?(Path.join(root, ".git"))
      end
    end

    test "the git tool commits under bwrap (git_write profile)", %{root: root} = ctx do
      if ctx[:skip] do
        :ok
      else
        init_git!(root)
        File.write!(Path.join(root, "app.txt"), "v1\n")

        put_sandbox(Bwrap)
        tool = CodingAgent.Core.Tools.Git.tool(%{root: root})

        assert {:ok, out} =
                 ReqLLM.Tool.execute(tool, %{
                   "args" => ["add", "app.txt"]
                 })

        assert out =~ "exit 0"

        assert {:ok, out} =
                 ReqLLM.Tool.execute(tool, %{
                   "args" => ["commit", "-m", "by git tool"]
                 })

        assert out =~ "exit 0"
        {log, 0} = System.cmd("git", ~w(log --oneline), cd: root, stderr_to_stdout: true)
        assert log =~ "by git tool"
      end
    end

    test "/tmp persists across separate calls when a session scope is present",
         %{root: root} = ctx do
      if ctx[:skip] do
        :ok
      else
        put_sandbox(Bwrap)
        session_id = "bwrap-scratch-#{System.unique_integer([:positive])}"
        scope = %{root: root, session_id: session_id}
        scratch = Scratch.path(session_id)
        on_exit(fn -> Scratch.remove(scratch) end)

        tool = Shell.tool(scope)

        # call 1 writes, call 2 (a fresh namespace) reads
        assert {:ok, _} = ReqLLM.Tool.execute(tool, %{"command" => "echo persisted > /tmp/x"})

        assert {:ok, out} = ReqLLM.Tool.execute(tool, %{"command" => "cat /tmp/x"})
        assert out =~ "persisted"

        # and TMPDIR agrees with the hardcoded /tmp
        assert {:ok, out} =
                 ReqLLM.Tool.execute(tool, %{"command" => "echo v > $TMPDIR/y; cat /tmp/y"})

        assert out =~ "v"
      end
    end

    test "the host's shared /tmp is not visible inside the sandbox", %{root: root} = ctx do
      if ctx[:skip] do
        :ok
      else
        put_sandbox(Bwrap)
        host_marker = Path.join(Scratch.base_dir(), "host-only-#{System.unique_integer()}")
        File.mkdir_p!(Scratch.base_dir())
        File.write!(host_marker, "secret")
        on_exit(fn -> File.rm(host_marker) end)

        tool = Shell.tool(%{root: root, session_id: "isolated"})
        on_exit(fn -> Scratch.remove(Scratch.path("isolated")) end)

        assert {:ok, out} = ReqLLM.Tool.execute(tool, %{"command" => "ls /tmp"})
        refute out =~ "host-only-"
      end
    end

    test "the git tool commits inside a linked worktree (git_write binds both gitdirs)",
         %{root: root} = ctx do
      if ctx[:skip] do
        :ok
      else
        {wt, _repo} = init_worktree!(root)
        File.write!(Path.join(wt, "b.txt"), "b\n")

        put_sandbox(Bwrap)
        tool = CodingAgent.Core.Tools.Git.tool(%{root: wt})

        assert {:ok, out} = ReqLLM.Tool.execute(tool, %{"args" => ["add", "b.txt"]})
        assert out =~ "exit 0"

        assert {:ok, out} = ReqLLM.Tool.execute(tool, %{"args" => ["commit", "-m", "wt commit"]})
        assert out =~ "exit 0"

        {log, 0} = System.cmd("git", ~w(log --oneline), cd: wt, stderr_to_stdout: true)
        assert log =~ "wt commit"
      end
    end

    test "git argv is not re-parsed by a shell inside the sandbox", %{root: root} = ctx do
      if ctx[:skip] do
        :ok
      else
        init_git!(root)
        marker = Path.join(root, "injected-#{System.unique_integer()}")
        put_sandbox(Bwrap)
        tool = CodingAgent.Core.Tools.Git.tool(%{root: root})

        assert {:ok, _out} =
                 ReqLLM.Tool.execute(tool, %{
                   "args" => ["log", "--oneline", "; touch #{marker}"]
                 })

        refute File.exists?(marker)
      end
    end
  end

  defp triple_in(argv, triple), do: sublist?(argv, Tuple.to_list(triple))

  defp sublist?(_list, []), do: true
  defp sublist?([], _), do: false

  defp sublist?([h | t], [h | t2]), do: sublist?(t, t2)

  defp sublist?([_ | t], needle), do: sublist?(t, needle)

  defp init_git!(root) do
    git!(root, ~w(init -q -b main))
    git!(root, ~w(config user.email test@example.com))
    git!(root, ~w(config user.name test))
  end

  # A repo plus a linked worktree at `<root>/wt`. Its `.git` is a gitfile
  # pointing at `<repo>/.git/worktrees/wt`, and the shared object/ref
  # store lives in `<repo>/.git`. Returns {worktree_dir, repo_dir}.
  defp init_worktree!(root) do
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    init_git!(repo)
    File.write!(Path.join(repo, "a.txt"), "a\n")
    git!(repo, ~w(add a.txt))
    git!(repo, ~w(commit -m init))

    wt = Path.join(root, "wt")

    {_, 0} =
      System.cmd("git", ["worktree", "add", "-b", "feature", wt],
        cd: repo,
        stderr_to_stdout: true
      )

    {wt, repo}
  end

  defp git!(root, args) do
    {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end
end
