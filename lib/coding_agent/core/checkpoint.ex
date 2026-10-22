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
    4. ``git commit-tree`` → a ROOT commit (no parent, review N53) so
       ``git gc`` can reclaim a snapshot the moment its ref is dropped;
    5. ``git update-ref
       refs/coding-agent/checkpoints/<store>/<session-id>/<commit>``
       → anchors the object against ``git gc``. The session id is in the
       name (review N54) so a ref can be attributed to a session without
       decoding its state, and the reconciliation pass (``reconcile/1``)
       can collect the orphans; the commit half keeps two sessions from
       colliding. The **store** segment (review N61) namespaces the ref by
       the store that owns the keep-set, so a repo shared by several stores
       or worktrees never has one store's reconciliation judge another's
       refs.

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
  through the ``git`` tool's profile (``change_vcs: true``). ``/undo`` is a
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
  ``{:error, reason}`` when git ran but failed.
  """
  @spec snapshot(map(), String.t()) :: {:ok, t()} | :skip | {:error, term()}
  def snapshot(scope, session_id) do
    root = Path.expand(scope.root)

    # The bind and the temp index must name the SAME scratch: build the
    # profile from the session id this checkpoint belongs to (the one the
    # ref carries), never from a possibly-different `scope.session_id`.
    profile = Git.profile(Map.put(scope, :session_id, session_id))

    case scratch_paths(session_id, profile) do
      nil ->
        :skip

      {tmp_host, tmp_sandbox} ->
        with :ok <- ensure_repo(scope, root) do
          File.mkdir_p!(Path.dirname(tmp_host))
          _ = File.rm(tmp_host)

          untracked = ls_untracked(scope, root)
          staged_tree = staged_tree(scope, root)

          with {:ok, tree} <- write_tree(scope, root, tmp_sandbox, profile),
               {:ok, commit} <- commit_tree(scope, root, tree),
               {:ok, ref} <- anchor(scope, root, session_id, commit) do
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

  @doc "The ref prefix every checkpoint uses."
  @spec ref_prefix() :: String.t()
  def ref_prefix, do: "refs/coding-agent/checkpoints/"

  @doc """
  Drops checkpoint refs whose session is GONE (review N54): killed before
  `Store.delete/1` ran, or deleted without cleanup. Returns the dropped
  refs.

  `known_sessions` is every session id that must be preserved — the
  store's persisted ids plus the live registry ids. A ref is dropped only
  when ALL hold:

    * it is in the NEW name form
      (``<prefix><store>/<session-id>/<commit>``) — so it can be attributed
      at all; and
    * its store segment is the SAME store the keep-set came from, so one
      store's reconciliation never judges another store's refs (review
      N61); and
    * its session segment is not in `known_sessions`.

  Legacy refs (``<prefix><commit>``, written before this change) are
  LEFT ALONE. They cannot be attributed, and per the review record that is
  exactly the shape holding the only surviving copy of a lost artefact —
  a reconciliation that cannot tell whose ref it is must not delete it.
  Best effort: a non-git root, or a git failure, drops nothing.
  """
  @spec reconcile(map(), [String.t()]) :: [String.t()]
  def reconcile(scope, known_sessions) do
    root = Path.expand(scope.root)
    known = known_sessions |> Enum.map(&ref_name/1) |> MapSet.new()

    case git(scope, root, ["for-each-ref", "--format=%(refname)", ref_prefix()], []) do
      {:ok, out, 0} ->
        out
        |> split_lines()
        |> Enum.filter(&String.starts_with?(&1, ref_prefix()))
        |> Enum.filter(&orphan?(&1, store_ns(), known))
        |> tap(fn refs -> Enum.each(refs, &drop_ref(scope, root, &1)) end)

      _ ->
        []
    end
  end

  # A ref is an orphan only if it is in the new (attributable) form, it is
  # in THIS store's namespace, and its session segment is unknown. The
  # commit half is a bare hash, no slash.
  defp orphan?(ref, store, known) do
    case ref |> String.replace_prefix(ref_prefix(), "") |> String.split("/", parts: 3) do
      [^store, session, _commit] -> not MapSet.member?(known, session)
      _other -> false
    end
  end

  # The store segment: the store DB path, sanitized to one ref-safe
  # segment. A path is unique per store, so this namespaces the ref without
  # a registry (review N61).
  defp store_ns, do: ref_name(CodingAgent.Core.Session.Store.path())

  # -- git plumbing -----------------------------------------------------------

  defp ensure_repo(scope, root) do
    case git(scope, root, ["rev-parse", "--is-inside-work-tree"], []) do
      {:ok, "true\n", 0} -> :ok
      _ -> :skip
    end
  end

  defp write_tree(scope, root, tmp_index, profile) do
    env = [{"GIT_INDEX_FILE", tmp_index}]

    with {:ok, _, 0} <- git(scope, root, ["add", "-A"], env, profile),
         {:ok, out, 0} <- git(scope, root, ["write-tree"], env, profile) do
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

  # A ROOT commit (no parent): review N53. Parenting each snapshot on the
  # previous one kept every trimmed snapshot reachable as an ancestor, so
  # `git gc` could never reclaim it and `checkpoint_depth` bounded only the
  # refs, not the objects. Nothing traverses the chain (Restore works off
  # `tree`/`staged_tree`), so dropping the parent costs nothing and lets a
  # dropped ref's objects be collected.
  defp commit_tree(scope, root, tree) do
    args = [
      "-c",
      "user.name=coding-agent",
      "-c",
      "user.email=coding-agent@localhost",
      "commit-tree",
      tree,
      "-m",
      "coding-agent checkpoint"
    ]

    case git(scope, root, args, []) do
      {:ok, out, 0} -> {:ok, String.trim(out)}
      {:ok, out, code} -> {:error, {:commit_tree_failed, code, String.trim(out)}}
    end
  end

  # The ref carries the STORE (review N61) and the SESSION id (review N54),
  # so a ref can be attributed to its store and session without decoding
  # state — which is what the reconciliation pass needs. The commit half
  # still disambiguates two snapshots of one session.
  defp anchor(scope, root, session_id, commit) do
    ref = ref_prefix() <> store_ns() <> "/" <> ref_name(session_id) <> "/" <> commit

    case git(scope, root, ["update-ref", ref, commit], []) do
      {:ok, _, 0} -> {:ok, ref}
      {:ok, out, code} -> {:error, {:anchor_failed, code, String.trim(out)}}
    end
  end

  # The ref path segment for a session id. git ref names forbid space,
  # `/` boundaries are ours, and `~^:?*[`, a leading dot, `..` and a
  # trailing `.lock` are forbidden. Session ids are `tui-<pid>` or
  # generated ids, but a renamed session could carry anything, so sanitize
  # rather than trust. Public so `reconcile/2` sanitizes the keep-set the
  # same way and cannot mismatch what `anchor/4` wrote.
  @doc false
  @spec ref_name(String.t()) :: String.t()
  def ref_name(session_id) do
    session_id
    |> to_string()
    |> String.replace(~r|[~^:?*\[\]\\/\s]+|, "-")
    |> String.replace("..", "-")
    |> String.trim_leading(".")
    |> String.trim_trailing(".lock")
    |> case do
      "" -> "unknown"
      name -> name
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
  # (change_vcs), non-interactively. cwd is the scope root.
  defp git(scope, root, args, env, profile \\ nil) do
    profile = profile || Git.profile(scope)

    case Exec.run({:exec, "git", args}, root, 60, profile, env: Exec.agent_env() ++ env) do
      {:ok, out, status} -> {:ok, out, status}
      {:timeout, _} -> {:error, :timeout}
      {:stopped, _} -> {:error, :stopped}
      {:sandbox_error, reason} -> {:error, {:sandbox, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The temporary index must be addressed by the path the CONFINED git sees,
  # not the host path: the sandbox may bind the session scratch OVER `/tmp`
  # (ADR 022), so `<scratch>/x` is `/tmp/x` in there. Only the sandbox knows
  # that mapping (`Sandbox.visible_path/2`), so we ask it rather than
  # hardcode `/tmp` — a pass-through sandbox (the test double) uses the host
  # path, and a future platform sandbox can bind differently. `{host_file,
  # sandbox_file}`, or nil when there is no session scratch (then `/tmp` is
  # a per-call tmpfs and the index could not survive between calls).
  defp scratch_paths(session_id, profile) do
    case CodingAgent.Core.Session.Scratch.from_scope(%{session_id: session_id}) do
      nil ->
        nil

      base ->
        host = Path.join(base, "checkpoint-index")
        {host, CodingAgent.Core.Sandbox.visible_path(host, profile)}
    end
  end

  defp split_lines(out) do
    out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end
end
