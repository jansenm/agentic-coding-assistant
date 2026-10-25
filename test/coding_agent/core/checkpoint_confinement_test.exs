defmodule CodingAgent.Core.CheckpointConfinementTest do
  @moduledoc """
  The checkpoint under the REAL bwrap sandbox (ADR 030/036): a checkpoint
  must work confined, which means the temporary index is addressed by its
  `/tmp/...` path (the session scratch is bound OVER `/tmp`, ADR 022), not
  by its host path. The stub sandbox cannot show this — only real bwrap
  can. bwrap is a hard dependency (ADR 030/046): `test_helper.exs`
  refuses to start the suite without it (review P13).
  """
  use ExUnit.Case, async: false

  import CodingAgent.SandboxCase

  alias CodingAgent.Core.Checkpoint
  alias CodingAgent.Core.Sandbox.Bwrap

  @root System.tmp_dir!() |> Path.join("agent-cp-conf-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(@root)
    git!(["init", "-q", "-b", "main"])
    git!(["config", "user.email", "t@example.com"])
    git!(["config", "user.name", "T"])
    File.write!(Path.join(@root, "a.txt"), "one\n")
    git!(["add", "-A"])
    git!(["commit", "-qm", "init"])

    on_exit(fn -> File.rm_rf!(@root) end)
    :ok
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args, cd: @root, stderr_to_stdout: true)
    out
  end

  defp scope(session_id) do
    %{root: @root, session_id: session_id, mounts: %{rw: [], ro: [], hide: []}}
  end

  test "snapshot and restore work confined (real bwrap)" do
    put_sandbox(Bwrap)
    sid = "conf-#{System.unique_integer([:positive])}"

    File.write!(Path.join(@root, "a.txt"), "human edit\n")
    {:ok, cp} = Checkpoint.snapshot(scope(sid), sid)

    File.write!(Path.join(@root, "a.txt"), "agent clobber\n")
    File.write!(Path.join(@root, "new.txt"), "agent made\n")

    assert :ok = Checkpoint.restore(scope(sid), cp)

    assert File.read!(Path.join(@root, "a.txt")) == "human edit\n"
    refute File.exists?(Path.join(@root, "new.txt"))
  end
end
