defmodule CodingAgent.Core.Session.CheckpointUndoTest do
  @moduledoc """
  Session-level integration for ADR 036: a checkpoint is taken before a
  turn can write, and `/undo` (``Session.undo/1``) restores the files.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session

  @root System.tmp_dir!() |> Path.join("agent-undo-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(@root)
    git!(["init", "-q", "-b", "main"])
    git!(["config", "user.email", "t@example.com"])
    git!(["config", "user.name", "T"])
    File.write!(Path.join(@root, "a.txt"), "committed\n")
    git!(["add", "-A"])
    git!(["commit", "-qm", "init"])

    on_exit(fn -> File.rm_rf!(@root) end)
    :ok
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args, cd: @root, stderr_to_stdout: true)
    out
  end

  defp read(name), do: File.read!(Path.join(@root, name))

  # A runner that simulates the turn's file writes and then completes.
  defp writing_runner(writes) do
    fn state ->
      Enum.each(writes, fn {name, content} ->
        File.write!(Path.join(@root, name), content)
      end)

      state = Session.debug_complete_turn(state, "done", [{:assistant, "done"}])
      {state, {:ok, state}}
    end
  end

  defp start(id, runner) do
    # test_mode false (like the async-turn tests): checkpoints are skipped
    # in test_mode so the suite never snapshots the harness repo, and this
    # file needs the real snapshot path. The turn_runner replaces the
    # provider loop, so no LLM is reached.
    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: id,
        scope_root: @root,
        test_mode: false,
        turn_runner: runner
      )
  end

  test "a checkpoint is taken before the turn, /undo restores the files" do
    id = "undo-#{System.unique_integer([:positive])}"

    # the human's dirty state before the turn
    File.write!(Path.join(@root, "a.txt"), "mine, edited\n")

    start(id, writing_runner([{"a.txt", "agent clobbered\n"}, {"new.txt", "agent made\n"}]))
    {:ok, _} = Session.run(id, "do the thing")

    # the turn's writes are on disk
    assert read("a.txt") == "agent clobbered\n"
    assert File.exists?(Path.join(@root, "new.txt"))

    assert {:ok, 0} = Session.undo(id)

    # restored to the pre-turn state (the human's dirty edit), and the
    # file the turn created is gone
    assert read("a.txt") == "mine, edited\n"
    refute File.exists?(Path.join(@root, "new.txt"))
  end

  test "undo with no checkpoint reports nothing to undo" do
    id = "undo-empty-#{System.unique_integer([:positive])}"
    start(id, fn state -> {state, {:ok, state}} end)

    assert {:error, :nothing_to_undo} = Session.undo(id)
  end

  test "a failing checkpoint is surfaced once as a note (review F3)" do
    id = "undo-warn-#{System.unique_integer([:positive])}"

    # make the object store unwritable so `git add -A` fails the snapshot
    # deterministically (the same EROFS shape the review measured in a
    # linked worktree). Restore perms so on_exit can clean up.
    objects = Path.join([@root, ".git", "objects"])
    File.chmod!(objects, 0o555)
    on_exit(fn -> File.chmod(objects, 0o755) end)

    start(id, fn state -> {state, {:ok, state}} end)
    :ok = Session.subscribe(id)
    {:ok, _} = Session.run(id, "do the thing")

    assert_receive {:agent, ^id, {:info, note}}, 1000
    assert note =~ "checkpoint failed"
    assert note =~ "/undo"

    {:ok, st} = Session.state(id)
    assert st.checkpoint_warned == true

    # a second turn does not repeat the note
    {:ok, _} = Session.run(id, "again")
    refute_received {:agent, ^id, {:info, _}}
  end

  test "checkpoints survive a resume" do
    id = "undo-resume-#{System.unique_integer([:positive])}"
    start(id, writing_runner([{"new.txt", "agent made\n"}]))
    {:ok, _} = Session.run(id, "go")

    # re-read the persisted state in a fresh process
    {:ok, st} = Session.state(id)
    assert [%{commit: _}] = st.checkpoints
  end

  test "deleting a session drops its checkpoint refs (ADR 036 cleanup)" do
    id = "undo-cleanup-#{System.unique_integer([:positive])}"
    start(id, writing_runner([{"new.txt", "agent made\n"}]))
    {:ok, _} = Session.run(id, "go")

    {:ok, st} = Session.state(id)
    [%{ref: ref}] = st.checkpoints
    assert git!(["for-each-ref", ref]) =~ ref

    :ok = CodingAgent.Core.Session.Store.delete(id)

    # the ref is gone; the user's own work is untouched
    assert git!(["for-each-ref", ref]) == ""
    assert File.exists?(Path.join(@root, "new.txt"))
  end
end
