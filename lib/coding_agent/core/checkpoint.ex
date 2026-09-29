defmodule CodingAgent.Core.Checkpoint do
  @moduledoc """
  Git-backed file checkpoints (ADR 036): the "Git is the undo mechanism"
  principle made usable.

  A checkpoint captures the scope worktree — tracked files, and untracked
  but not ignored files — as a git tree object, **without touching** the
  human's ``HEAD``, index, stash or branches. ``restore/2`` puts the
  worktree back to a checkpoint and removes files created since, again
  leaving the human's staged state exactly as it was.

  The mechanism (snapshot):

    1. ``git add -A`` under a **temporary index** (``GIT_INDEX_FILE`` in
       the session scratch), so the real index is never written;
    2. ``git write-tree`` → the tree object;
    3. ``git commit-tree`` → a commit (parented on the previous
       checkpoint) so the objects are reachable;
    4. ``git update-ref refs/coding-agent/checkpoints/<session>/<commit>``
       → anchors the object against ``git gc``.

  Restore:

    1. back up the real index file, ``git read-tree --reset -u <tree>``
       (index + worktree = the checkpoint), then put the human's index
       back — so a pre-existing staged state is preserved;
    2. delete every untracked file that was NOT untracked at checkpoint
       time (the files the turn created) — ignored files are never
       touched;
    3. drop the checkpoint ref.

  Everything runs confined through the ``git`` tool's profile
  (``git_write: true``), so ADR 030 holds for the git work. ``/undo`` is a
  human verb, not an agent tool call, so the harness itself backs up and
  restores the real index file and unlinks the created files — the agent
  never gains an unconfined filesystem call.
  """

  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.Tools.Git

  @typedoc "One checkpoint: enough to restore the worktree."
  @type t :: %{
          ref: String.t(),
          commit: String.t(),
          tree: String.t(),
          # the human's staged content at snapshot time, as a backup file
          # in the scratch dir; nil when there was no index file
          index_backup: String.t() | nil,
          # untracked, non-ignored paths at snapshot time (relative to
          # root); used to keep the human's own untracked files on restore
          untracked: [String.t()],
          at: integer()
        }

  @doc """
  Captures the worktree as a checkpoint.

  Returns ``{:ok, checkpoint}`` on success, ``:skip`` when the scope root
  is not a git work tree (nothing to undo), or ``{:error, reason}`` when
  git ran but failed. `previous` is the parent commit for the chain, or
  nil for the first checkpoint in a session.
  """
  @spec snapshot(map(), String.t(), String.t() | nil) :: {:ok, t()} | :skip | {:error, term()}
  def snapshot(scope, session_id, previous \\ nil) do
    root = Path.expand(scope.root)

    case scratch_paths(scope, session_id) do
      nil ->
        # No session scratch: `/tmp` inside the sandbox is a fresh tmpfs
        # per call, so the temporary index could not survive from
        # `add -A` to `write-tree`. Skip rather than corrupt.
        :skip

      {tmp_host, tmp_sandbox} ->
        with :ok <- ensure_repo(scope, root) do
          File.mkdir_p!(Path.dirname(tmp_host))
          _ = File.rm(tmp_host)

          untracked = ls_untracked(scope, root)
          index_backup = backup_index(scope, root, session_id)

          with {:ok, tree} <- write_tree(scope, root, tmp_sandbox),
               {:ok, commit} <- commit_tree(scope, root, tree, previous),
               {:ok, ref} <- anchor(scope, root, session_id, commit) do
            {:ok,
             %{
               ref: ref,
               commit: commit,
               tree: tree,
               index_backup: index_backup,
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
         :ok <- remove_created(scope, root, checkpoint.untracked),
         :ok <- restore_index(scope, root, checkpoint.index_backup) do
      drop_ref(scope, root, checkpoint.ref)
      :ok
    end
  end

  @doc """
  Drops a checkpoint's ref (used when the stack is trimmed by depth).
  Best effort: a missing ref is not an error.
  """
  @spec drop(map(), t()) :: :ok
  def drop(scope, checkpoint) do
    root = Path.expand(scope.root)
    drop_ref(scope, root, checkpoint.ref)
    :ok
  end

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

  defp anchor(scope, root, session_id, commit) do
    ref = "refs/coding-agent/checkpoints/#{safe_id(session_id)}/#{commit}"

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
      full = Path.join(root, path)
      _ = File.rm_rf(full)
    end

    :ok
  end

  # The human's staged state is theirs: back the index file up before
  # `read-tree` rewrites it, and put it back afterwards. Resolved via git
  # so a worktree/submodule index (not `<root>/.git/index`) is right.
  defp backup_index(scope, root, session_id) do
    with {:ok, out, 0} <- git(scope, root, ["rev-parse", "--git-path", "index"], []),
         index_path <- out |> String.trim() |> Path.expand(root),
         true <- File.exists?(index_path) do
      dest = Path.join(scratch_dir(scope, session_id), "checkpoint-index.bak")
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(index_path, dest)
      dest
    else
      _ -> nil
    end
  end

  defp restore_index(scope, root, nil) do
    # there was no index file at snapshot time: remove the one read-tree
    # created, reproducing the original "no index" state.
    case git(scope, root, ["rev-parse", "--git-path", "index"], []) do
      {:ok, out, 0} -> File.rm(out |> String.trim() |> Path.expand(root))
      _ -> :ok
    end

    :ok
  end

  defp restore_index(scope, root, backup) do
    with {:ok, out, 0} <- git(scope, root, ["rev-parse", "--git-path", "index"], []) do
      target = out |> String.trim() |> Path.expand(root)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(backup, target)
      :ok
    end
  end

  # Run one git command through the sandbox under the git tool's profile
  # (git_write), non-interactively. cwd is the scope root.
  defp git(scope, root, args, env) do
    case Exec.run({:exec, "git", args}, root, 60, Git.profile(scope),
           env: Exec.agent_env() ++ env
         ) do
      {:ok, out, status} -> {:ok, out, status}
      {:timeout, _} -> {:error, :timeout}
      {:sandbox_error, reason} -> {:error, {:sandbox, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scratch_dir(_scope, session_id) do
    case CodingAgent.Core.Session.Scratch.from_scope(%{session_id: session_id}) do
      nil -> Path.join(System.tmp_dir!(), "coding-agent")
      base -> base
    end
  end

  # The temporary index must be addressed by the path the CONFINED git
  # sees, not the host path: the session scratch dir is bound OVER `/tmp`
  # inside the sandbox (ADR 022), so `<scratch>/x` is `/tmp/x` in there.
  # `{host_file, sandbox_file}`, or nil when there is no session scratch
  # (then `/tmp` is a per-call tmpfs and the index could not survive
  # between calls).
  defp scratch_paths(_scope, session_id) do
    case CodingAgent.Core.Session.Scratch.from_scope(%{session_id: session_id}) do
      nil -> nil
      base -> {Path.join(base, "checkpoint-index"), "/tmp/checkpoint-index"}
    end
  end

  defp split_lines(out) do
    out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  # A ref name may not contain most punctuation; session ids are tame
  # (`tui-123`) but the rule is enforced rather than assumed.
  defp safe_id(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "-")
end
