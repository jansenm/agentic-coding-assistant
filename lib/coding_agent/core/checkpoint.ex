defmodule CodingAgent.Core.Checkpoint do
  @moduledoc """
  Git-backed file checkpoints (ADR 036): the "Git is the undo mechanism"
  principle made usable.

  A checkpoint captures the scope worktree — tracked files, and untracked
  but not ignored files — as a git tree object, **without touching** the
  human's ``HEAD``, index, stash or branches. It also records the human's
  **staged** tree (the real index as its own tree), so ``restore/2`` puts
  the worktree back to the checkpoint *and* leaves the staged state
  exactly as it was.

  Snapshot:

    1. ``git add -A`` under a **temporary index** (``GIT_INDEX_FILE`` in
       the session scratch, ADR 022), so the real index is never written;
    2. ``git write-tree`` → the worktree tree object;
    3. ``git write-tree`` on the REAL index → the staged tree;
    4. ``git commit-tree`` → a commit (parented on the previous
       checkpoint) so the objects are reachable;
    5. ``git update-ref refs/coding-agent/checkpoints/<commit>`` → anchors
       the object against ``git gc``; the ref is keyed by the commit, so
       two sessions in one repo cannot collide and a rename needs no fix.

  Restore:

    1. ``git read-tree --reset -u <worktree-tree>`` → index + worktree =
       the checkpoint;
    2. ``git read-tree <staged-tree>`` → the index is the human's staged
       state again (worktree untouched);
    3. every file untracked *now* but not untracked at snapshot time is
       removed (what the turn created) — ignored files are never listed;
    4. drop the checkpoint ref.

  The temp index is addressed by its ``/tmp/...`` path (the scratch is
  bound OVER ``/tmp``), never the host path. All git work runs confined
  through the ``git`` tool's profile (``git_write: true``). ``/undo`` is a
  human verb, not an agent tool call, so the harness itself unlinks the
  created files: the agent gains no unconfined filesystem call.
  """

  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.Tools.Git

  @typedoc "One checkpoint: enough to restore the worktree."
  @type t :: %{
          ref: String.t(),
          commit: String.t(),
          tree: String.t(),
          # the human's staged tree at snapshot time (git write-tree on the
          # real index); nil when it could not be read (unmerged index)
          staged_tree: String.t() | nil,
          # untracked, non-ignored paths at snapshot time (relative to
          # root); used to keep the human's own untracked files on restore
          untracked: [String.t()],
          at: integer()
        }

  @doc """
  Captures the worktree as a checkpoint.

  Returns ``{:ok, checkpoint}`` on success, ``:skip`` when the scope root
  is not a git work tree (nothing to undo) or there is no session scratch
  (a per-call tmpfs ``/tmp`` cannot carry the temp index), or
  ``{:error, reason}`` when git ran but failed. `previous` is the parent
  commit for the chain, or nil for the first checkpoint in a session.
  """
  @spec snapshot(map(), String.t(), String.t() | nil) :: {:ok, t()} | :skip | {:error, term()}
  def snapshot(scope, session_id, previous \\ nil) do
    root = Path.expand(scope.root)

    case scratch_paths(session_id) do
      nil ->
        :skip

      {tmp_host, tmp_sandbox} ->
        with :ok <- ensure_repo(scope, root) do
          File.mkdir_p!(Path.dirname(tmp_host))
          _ = File.rm(tmp_host)

          untracked = ls_untracked(scope, root)
          staged_tree = staged_tree(scope, root)

          with {:ok, tree} <- write_tree(scope, root, tmp_sandbox),
               {:ok, commit} <- commit_tree(scope, root, tree, previous),
               {:ok, ref} <- anchor(scope, root, commit) do
            {:ok,
             %{
               ref: ref,
               commit: commit,
               tree: tree,
               staged_tree: staged_tree,
               untracked: untracked,
               at: System.system_time(:millisecond)
             }}
          end
        end
    end
  end

  @doc """
  Restores the worktree to `checkpoint`, removes files created since, and
  drops the checkpoint ref. Never touches ignored files or the human's
  staged content.
  """
  @spec restore(map(), t()) :: :ok | {:error, term()}
  def restore(scope, checkpoint) do
    root = Path.expand(scope.root)

    with :ok <- ensure_repo(scope, root),
         :ok <- read_tree(scope, root, checkpoint.tree),
         :ok <- restore_staged(scope, root, checkpoint.staged_tree),
         :ok <- remove_created(scope, root, checkpoint.untracked) do
      drop_ref(scope, root, checkpoint.ref)
      :ok
    end
  end

  @doc """
  Drops a checkpoint's ref (used when the stack is trimmed by depth, and
  when a session is deleted). Best effort: a missing ref is not an error.
  """
  @spec drop(map(), t()) :: :ok
  def drop(scope, checkpoint) do
    drop_ref(scope, Path.expand(scope.root), checkpoint.ref)
    :ok
  end

  @doc false
  # The ref prefix every checkpoint uses. Exposed so a cleanup path can
  # reason about (or garbage-collect) the namespace.
  def ref_prefix, do: "refs/coding-agent/checkpoints/"

  # -- git plumbing -----------------------------------------------------------

  defp ensure_repo(scope, root) do
    case git(scope, root, ["rev-parse", "--is-inside-work-tree"], []) do
      {:ok, "true\n", 0} -> :ok
      _ -> :skip
    end
  end

  defp write_tree(scope, root, tmp_index) do
    env = [{"GIT_INDEX_FILE", tmp_index}]

    with {:ok, _, 0} <- git(scope, root, ["add", "-A"], env),
         {:ok, out, 0} <- git(scope, root, ["write-tree"], env) do
      {:ok, String.trim(out)}
    else
      {:ok, out, code} -> {:error, {:write_tree_failed, code, String.trim(out)}}
    end
  end

  # The human's staged state as a tree, read from the REAL index without
  # writing it. Best effort: an unmerged index cannot be written (nil).
  defp staged_tree(scope, root) do
    case git(scope, root, ["write-tree"], []) do
      {:ok, out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp commit_tree(scope, root, tree, previous) do
    args =
      [
        "-c",
        "user.name=coding-agent",
        "-c",
        "user.email=coding-agent@localhost",
        "commit-tree",
        tree
      ] ++
        if(previous, do: ["-p", previous], else: []) ++ ["-m", "coding-agent checkpoint"]

    case git(scope, root, args, []) do
      {:ok, out, 0} -> {:ok, String.trim(out)}
      {:ok, out, code} -> {:error, {:commit_tree_failed, code, String.trim(out)}}
    end
  end

  defp anchor(scope, root, commit) do
    ref = ref_prefix() <> commit

    case git(scope, root, ["update-ref", ref, commit], []) do
      {:ok, _, 0} -> {:ok, ref}
      {:ok, out, code} -> {:error, {:anchor_failed, code, String.trim(out)}}
    end
  end

  defp read_tree(scope, root, tree) do
    case git(scope, root, ["read-tree", "--reset", "-u", tree], []) do
      {:ok, _, 0} -> :ok
      {:ok, out, code} -> {:error, {:read_tree_failed, code, String.trim(out)}}
    end
  end

  # Put the human's staged entries back (index only; the worktree was set
  # by `read_tree/3`). No `-u`, so files on disk are untouched.
  defp restore_staged(_scope, _root, nil), do: :ok

  defp restore_staged(scope, root, staged_tree) do
    case git(scope, root, ["read-tree", staged_tree], []) do
      {:ok, _, 0} -> :ok
      {:ok, out, code} -> {:error, {:restore_staged_failed, code, String.trim(out)}}
    end
  end

  defp drop_ref(scope, root, ref) do
    _ = git(scope, root, ["update-ref", "-d", ref], [])
    :ok
  end

  defp ls_untracked(scope, root) do
    case git(scope, root, ["ls-files", "--others", "--exclude-standard"], []) do
      {:ok, out, 0} -> split_lines(out)
      _ -> []
    end
  end

  # Delete the files that are untracked NOW but were not at snapshot time:
  # exactly what the turn created. Ignored files never appear (the
  # `--exclude-standard` list excludes them), so they are never removed.
  defp remove_created(scope, root, before) do
    before = MapSet.new(before)

    for path <- ls_untracked(scope, root), not MapSet.member?(before, path) do
      _ = File.rm_rf(Path.join(root, path))
    end

    :ok
  end

  # Run one git command through the sandbox under the git tool's profile
  # (git_write), non-interactively. cwd is the scope root.
  defp git(scope, root, args, env) do
    case Exec.run({:exec, "git", args}, root, 60, Git.profile(scope),
           env: Exec.agent_env() ++ env
         ) do
      {:ok, out, status} -> {:ok, out, status}
      {:timeout, _} -> {:error, :timeout}
      {:stopped, _} -> {:error, :stopped}
      {:sandbox_error, reason} -> {:error, {:sandbox, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The temporary index must be addressed by the path the CONFINED git
  # sees, not the host path: the session scratch dir is bound OVER `/tmp`
  # inside the sandbox (ADR 022), so `<scratch>/x` is `/tmp/x` in there.
  # `{host_file, sandbox_file}`, or nil when there is no session scratch
  # (then `/tmp` is a per-call tmpfs and the index could not survive
  # between calls).
  defp scratch_paths(session_id) do
    case CodingAgent.Core.Session.Scratch.from_scope(%{session_id: session_id}) do
      nil -> nil
      base -> {Path.join(base, "checkpoint-index"), "/tmp/checkpoint-index"}
    end
  end

  defp split_lines(out) do
    out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end
end
