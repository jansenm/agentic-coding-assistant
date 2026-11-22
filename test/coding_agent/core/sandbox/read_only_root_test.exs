# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Sandbox.ReadOnlyRootTest do
  @moduledoc """
  The LIVE read-only-root behaviour (`shell: read_only`): under real bwrap
  the scope root is bound `--ro-bind`, so archaeology works and writes
  fail. `async: false` because it switches the global `:sandbox` app env.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.Sandbox.Bwrap
  alias CodingAgent.Core.Tools.Shell

  @tmp_root System.tmp_dir!() |> Path.join("agent-ro-root-#{System.unique_integer([:positive])}")

  setup do
    prev = Application.get_env(:coding_agent, :sandbox)
    on_exit(fn -> Application.put_env(:coding_agent, :sandbox, prev) end)
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  # bwrap is a hard dependency (ADR 030/046): test_helper.exs refuses to
  # start the suite without it, so this test always runs (review P13).
  test "reads and git archaeology work; writes fail with a read-only filesystem" do
    Application.put_env(:coding_agent, :sandbox, Bwrap)

    root = Path.join(@tmp_root, "repo")
    File.mkdir_p!(root)
    git!(root, ["init", "-q", "-b", "main"])
    File.write!(Path.join(root, "f.txt"), "hello\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-qm", "one"])
    File.write!(Path.join(root, "f.txt"), "hello\nworld\n")

    profile = Shell.profile(%{root: root, shell_mode: :ro}, %{})

    run = fn cmd -> Exec.run({:shell, cmd}, root, 15, profile) end

    # reads succeed
    {:ok, out, 0} = run.("cat f.txt")
    assert out =~ "hello"

    # git archaeology succeeds, and SEES the uncommitted change
    {:ok, log, 0} = run.("git log --oneline")
    assert log =~ "one"
    {:ok, status, 0} = run.("git status --porcelain")
    assert status =~ "M f.txt"
    {:ok, diff, 0} = run.("git diff --stat")
    assert diff =~ "f.txt"

    # write commands fail: the source cannot be mutated
    for cmd <- ["echo x > g.txt", "mkdir build", "rm f.txt", "touch build.out"] do
      {:ok, _out, code} = run.(cmd)
      assert code != 0, "#{cmd} unexpectedly succeeded"
    end

    refute File.exists?(Path.join(root, "g.txt"))
    refute File.exists?(Path.join(root, "build"))
    refute File.exists?(Path.join(root, "build.out"))
    assert File.exists?(Path.join(root, "f.txt"))
  end

  defp git!(root, args) do
    {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end
end
