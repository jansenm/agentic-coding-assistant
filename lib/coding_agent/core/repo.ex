defmodule CodingAgent.Core.Repo do
  @moduledoc """
  Locating the repository root above a working directory.

  Three places need the same answer — "where does the enclosing repo
  start?" — and each used to guess differently, or not at all:

    * `ProjectMemory` (nested `AGENTS.md`, review T13): read every
      `AGENTS.md` from the git root down to the scope.
    * `Sandbox.Bwrap.git_dirs/1`: a `scope_root` that is a SUBDIRECTORY of
      the checkout found no `.git`, so `git add`/`commit` and the
      checkpoint index died with EROFS (the read-only `/` bind) — silently.

    * `UserConfig`: `<scope_root>/.coding-agent/*.toml` was not found when
      the config lived at the repo root and the session started lower.

  One rule answers all three: walk UP from the directory until a `.git`
  entry is found (a directory for a normal checkout, a FILE for a
  worktree/submodule gitfile). Filesystem-only — no `git` invocation — so
  it is cheap, pure enough for `argv/3`, and works under the read-only
  root. A directory with no git above it returns `nil`; callers keep
  their existing "no git here" behavior (no checkpoint, no repo config).

  The walk stops at the git root, never above it: `AGENTS.md` or
  `.coding-agent/` in a parent *outside* the repo are not ours.
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

  @doc """
  Every directory from the git root down to `scope_root` (root first,
  scope last), or `[scope_root]` alone when there is no enclosing repo.
  This is the order `AGENTS.md` wants: general to specific.
  """
  @spec dirs(String.t() | nil) :: [String.t()]
  def dirs(nil), do: []

  def dirs(scope_root) do
    scope = Path.expand(scope_root)

    case root(scope) do
      nil -> [scope]
      git -> up_from(git, scope)
    end
  end

  defp up_from(git, scope, acc \\ [])

  defp up_from(git, scope, acc) do
    acc = [scope | acc]

    if scope == git or Path.dirname(scope) == scope,
      do: acc,
      else: up_from(git, Path.dirname(scope), acc)
  end
end
