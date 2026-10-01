defmodule CodingAgent.Core.CheckpointTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Checkpoint

  @root System.tmp_dir!() |> Path.join("agent-checkpoint-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(@root)
    git!(["init", "-q", "-b", "main"])
    git!(["config", "user.email", "t@example.com"])
    git!(["config", "user.name", "T"])

    on_exit(fn -> File.rm_rf!(@root) end)
    %{scope: %{root: @root, session_id: "s1", mounts: %{rw: [], ro: [], hide: []}}}
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args, cd: @root, stderr_to_stdout: true)
    out
  end

  defp write(name, content), do: File.write!(Path.join(@root, name), content)
  defp read(name), do: File.read!(Path.join(@root, name))

  test "snapshot then restore brings tracked and untracked files back", %{scope: scope} do
    write("tracked.txt", "one\n")
    git!(["add", "-A"])
    git!(["commit", "-qm", "init"])

    # the human's dirty work: an edit + an untracked file
    write("tracked.txt", "one\ntwo\n")
    write("human_untracked.txt", "mine\n")

    {:ok, cp} = Checkpoint.snapshot(scope, "s1")

    # the turn mutates: more edits, a new file
    write("tracked.txt", "one\ntwo\nthree\n")
    write("agent_created.txt", "agent\n")

    assert :ok = Checkpoint.restore(scope, cp)

    assert read("tracked.txt") == "one\ntwo\n"
    assert read("human_untracked.txt") == "mine\n"
    refute File.exists?(Path.join(@root, "agent_created.txt"))
  end

  test "restore brings back an overwritten untracked file", %{scope: scope} do
    write("tracked.txt", "t\n")
    git!(["add", "-A"])
    git!(["commit", "-qm", "init"])

    # an untracked file that is part of the human's dirty state
    write("scratch.txt", "mine\n")
    {:ok, cp} = Checkpoint.snapshot(scope, "s1")

    # the turn overwrites it
    write("scratch.txt", "agent overwrote\n")

    :ok = Checkpoint.restore(scope, cp)
    assert read("scratch.txt") == "mine\n"
  end

  test "restore never deletes ignored files", %{scope: scope} do
    write(".gitignore", "*.log\n")
    write("a.txt", "a\n")
    git!(["add", "-A"])
    git!(["commit", "-qm", "init"])

    write("build.log", "keep me\n")
    {:ok, cp} = Checkpoint.snapshot(scope, "s1")

    write("later.log", "also keep me\n")
    write("new.txt", "remove me\n")

    :ok = Checkpoint.restore(scope, cp)

    assert File.exists?(Path.join(@root, "build.log"))
    assert File.exists?(Path.join(@root, "later.log"))
    refute File.exists?(Path.join(@root, "new.txt"))
    assert File.exists?(Path.join(@root, ".gitignore"))
  end

  test "restore preserves the human's staged state", %{scope: scope} do
    write("a.txt", "committed\n")
    git!(["add", "-A"])
    git!(["commit", "-qm", "init"])

    write("a.txt", "staged\n")
    write("b.txt", "staged too\n")
    git!(["add", "a.txt", "b.txt"])

    {:ok, cp} = Checkpoint.snapshot(scope, "s1")

    # a turn clobbers one file and adds another
    write("a.txt", "agent overwrote\n")
    write("c.txt", "agent made\n")

    :ok = Checkpoint.restore(scope, cp)

    # the human's staged change survives exactly
    staged = git!(["diff", "--cached", "--name-only"]) |> String.split("\n", trim: true)
    assert "a.txt" in staged
    assert "b.txt" in staged
    assert read("a.txt") == "staged\n"
    refute File.exists?(Path.join(@root, "c.txt"))
  end

  test "snapshot is a no-op outside a git work tree" do
    # a directory that is NOT inside any git repo (not under @root)
    plain = System.tmp_dir!() |> Path.join("agent-norepo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf!(plain) end)
    assert Checkpoint.snapshot(%{root: plain, session_id: "s2"}, "s2") == :skip
  end

  # Regression: two checkpoints in the SAME repo must not share one index
  # backup (they used to overwrite each other's, losing the older staged
  # state). The staged tree is now stored per checkpoint.
  test "each checkpoint preserves ITS OWN staged state", %{scope: scope} do
    write("a.txt", "v1\n")
    git!(["add", "-A"])
    git!(["commit", "-qm", "init"])

    write("a.txt", "staged-A\n")
    git!(["add", "a.txt"])
    {:ok, cp_a} = Checkpoint.snapshot(scope, "s1")

    write("a.txt", "staged-B\n")
    git!(["add", "a.txt"])
    {:ok, cp_b} = Checkpoint.snapshot(scope, "s1")

    # restore the OLDER checkpoint: its staged state must win
    :ok = Checkpoint.restore(scope, cp_a)
    assert git!(["show", ":a.txt"]) == "staged-A\n"
    assert read("a.txt") == "staged-A\n"

    # and the newer one still has its own
    :ok = Checkpoint.restore(scope, cp_b)
    assert git!(["show", ":a.txt"]) == "staged-B\n"
  end

  test "the ref carries the session id AND the commit (reviews N54)", %{scope: scope} do
    write("a.txt", "v1\n")
    git!(["add", "-A"])
    git!(["commit", "-qm", "init"])

    {:ok, cp} = Checkpoint.snapshot(scope, "s1")
    assert cp.ref == Checkpoint.ref_prefix() <> "s1/" <> cp.commit
  end

  test "each snapshot is a ROOT commit, not chained (review N53)", %{scope: scope} do
    # The chain used to pin every trimmed snapshot as an ancestor, so git
    # gc could never reclaim it. Root commits let a dropped ref's objects
    # go. Two snapshots must not share ancestry.
    write("a.txt", "v1\n")
    git!(["add", "-A"])
    git!(["commit", "-qm", "init"])

    {:ok, cp1} = Checkpoint.snapshot(scope, "s1")
    write("a.txt", "v2\n")
    {:ok, cp2} = Checkpoint.snapshot(scope, "s1")

    assert cp1.commit != cp2.commit
    # cp2 is a root commit: exactly one reachable commit (itself)
    assert git!(["rev-list", "--count", cp2.commit]) == "1\n"
    # and cp1 is NOT an ancestor of cp2
    {_out, code} =
      System.cmd("git", ["merge-base", "--is-ancestor", cp1.commit, cp2.commit],
        cd: @root,
        stderr_to_stdout: true
      )

    assert code == 1
  end

  test "snapshot then restore drops only its own ref", %{scope: scope} do
    write("a.txt", "v1\n")
    git!(["add", "-A"])
    git!(["commit", "-qm", "init"])

    {:ok, cp1} = Checkpoint.snapshot(scope, "s1")
    write("a.txt", "v2\n")
    {:ok, cp2} = Checkpoint.snapshot(scope, "s1")

    # both refs exist
    refs = git!(["for-each-ref", "refs/coding-agent/checkpoints/"])
    assert refs =~ cp1.commit
    assert refs =~ cp2.commit

    :ok = Checkpoint.restore(scope, cp2)
    # the restored ref is gone; the older one remains
    refs = git!(["for-each-ref", "refs/coding-agent/checkpoints/"])
    refute refs =~ cp2.commit
    assert refs =~ cp1.commit
  end

  describe "reconcile/2 (review N54)" do
    test "drops refs of unknown sessions, keeps known and live ones", %{scope: scope} do
      write("a.txt", "v1\n")
      git!(["add", "-A"])
      git!(["commit", "-qm", "init"])

      {:ok, cp_live} = Checkpoint.snapshot(scope, "tui-live")
      # different content, so the two commits differ (same tree would hash
      # the same within a second)
      write("a.txt", "v2\n")
      {:ok, cp_dead} = Checkpoint.snapshot(scope, "tui-dead")

      # only "tui-live" is known
      dropped = Checkpoint.reconcile(scope, ["tui-live"])

      assert cp_dead.ref in dropped
      refute cp_live.ref in dropped
      refs = git!(["for-each-ref", "refs/coding-agent/checkpoints/"])
      assert refs =~ cp_live.commit
      refute refs =~ cp_dead.commit
    end

    test "never touches a LEGACY ref (no session segment)", %{scope: scope} do
      # A pre-N54 ref name is `<prefix><commit>`: unattributable. The
      # reconciliation must leave it — the review record notes such a ref
      # is exactly what preserved a lost artefact.
      write("a.txt", "v1\n")
      git!(["add", "-A"])
      git!(["commit", "-qm", "init"])

      tree = git!(["write-tree"]) |> String.trim()

      legacy =
        System.cmd(
          "git",
          [
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@e.com",
            "commit-tree",
            tree,
            "-m",
            "legacy"
          ],
          cd: @root,
          stderr_to_stdout: true
        )
        |> elem(0)
        |> String.trim()

      git!(["update-ref", Checkpoint.ref_prefix() <> legacy, legacy])

      dropped = Checkpoint.reconcile(scope, [])

      refute (Checkpoint.ref_prefix() <> legacy) in dropped
      assert git!(["for-each-ref", "refs/coding-agent/checkpoints/"]) =~ legacy
    end
  end
end
