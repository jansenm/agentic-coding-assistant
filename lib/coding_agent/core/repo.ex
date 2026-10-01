defmodule CodingAgent.Core.Repo do
  @moduledoc """
  Locating the repository root above a working directory.

  One place needs the answer — "where does the enclosing repo start?":

    * `Sandbox.Bwrap.git_dirs/1`: a `scope_root` that is a SUBDIRECTORY of
      the checkout finds no `.git` at the scope root, so `git add`/`commit`
      and the checkpoint index died with EROFS (the read-only `/` bind) —
      silently. A `git worktree` is the same shape: `.git` is a FILE at the
      scope root, so we follow it the same way.

  One rule answers it: walk UP from the directory until a `.git` entry is
  found (a directory for a normal checkout, a FILE for a worktree/submodule
  gitfile). Filesystem-only — no `git` invocation — so it is cheap, pure
  enough for `argv/3`, and works under the read-only root. A directory with
  no git above it returns `nil`; the caller keeps its "no git here"
  behavior.

  The walk stops at the git root, never above it: `.git` in a parent
  *outside* the repo is not ours.

  Note that the SCOPE ROOT itself never moves: `.coding-agent/` and
  `AGENTS.md` are read at the scope root alone (`Core.UserConfig`,
  `Core.ProjectMemory`), not here. Only the sandbox bind needs `.git`,
  wherever it lives.
  """

  @doc """
  The nearest ancestor of `dir` (inclusive) holding a `.git` entry, or
  `nil` when there is none up to the filesystem root.
  """
  @spec root(String.t() | nil) :: String.t() | nil
  def root(nil), do: nil

  def root(dir) when is_binary(dir) do
    dir = Path.expand(dir)

    cond do
      File.exists?(Path.join(dir, ".git")) -> dir
      Path.dirname(dir) == dir -> nil
      true -> root(Path.dirname(dir))
    end
  end
end
