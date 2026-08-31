defmodule CodingAgent.Core.Containment do
  @moduledoc """
  THE containment discipline for every filesystem access a tool makes
  (ADR 010 + the path-hardening lessons).

  One rule, now encoded in one place so tools cannot re-forget it:

  > In any filesystem walk, **every** entry — file *or* directory —
  > passes the scope check before it is used. A symlinked directory
  > pointing outside the scope is a walkable escape (slice 2d bug #1);
  > a symlinked file pointing out is a listing/read leak (slice 2d
  > bug #2). Both variants of the same mistake.

  Consumers:

  - `path_allowed?/2` — the single-path predicate (physical symlink
    resolution included). For one-file tools (`read_file`,
    `write_file`, `list_dir`).
  - `walk/3` — THE containment-respecting directory walk. Any tool
    that lists or searches a tree goes through here; there is exactly
    one `cond` to guard, and the guard tests attack exactly it.
  - `default_skip_dirs/0` — the shared build/vendor/hidden skip list.

  If you are about to call `CodingAgent.Core.Tools.in_scope?/2` to
  hand-roll a walk: don't. Use `walk/3` (or extend it).
  """

  alias CodingAgent.Core.Tools

  @skip_dirs MapSet.new(["_build", "deps", ".git", "doc", "cover", ".elixir_ls"])

  @max_entries 2000

  @typedoc "Options for `walk/3`."
  @type walk_opt ::
          {:match_files, (String.t() -> boolean())}
          | {:skip_dirs, MapSet.t()}
          | {:max_entries, pos_integer()}

  @doc """
  Single-path containment check. Delegates to `Tools.in_scope?/2`;
  kept here so tools and this module read from one vocabulary.
  """
  @spec path_allowed?(Tools.scope(), String.t()) :: boolean()
  def path_allowed?(scope, path), do: Tools.in_scope?(scope, path)

  @doc "The scope check as a directive, for tool callbacks."
  @spec check_scope!(Tools.scope(), String.t()) :: :ok | {:error, String.t()}
  def check_scope!(scope, path) do
    if path_allowed?(scope, path) do
      :ok
    else
      Tools.error("path escapes the session scope: #{inspect(path)}")
    end
  end

  @doc """
  Walks a directory tree inside the scope and returns in-scope files.

  Containment contract (the reason this function exists):

  - every directory is scope-checked *before descending* — a symlinked
    dir pointing outside contributes nothing and is not entered;
  - every file is scope-checked *before being yielded* — a symlinked
    file pointing out is skipped, never listed;
  - skip dirs (shared default + opts) are pruned before containment —
    they are noise, not security.

  Options:

    - `:match_files` — filter on the *file name* (entry name, not the
      whole path), e.g. a glob.
    - `:skip_dirs` — extra dir names to prune (defaults from
      `default_skip_dirs/0`; hidden dirs always pruned).
    - `:max_entries` — walk budget; the walk stops adding once hit
      (breadth over the file entries already collected).

  Returns a flat list of absolute file paths in deterministic order.
  """
  @spec walk(Tools.scope(), String.t(), [walk_opt()]) :: [String.t()]
  def walk(scope, path, opts \\ []) do
    root = Path.expand(scope.root)
    start = Path.expand(path, root)

    if File.dir?(start) and path_allowed?(scope, start) do
      match_files = Keyword.get(opts, :match_files)
      skip = Keyword.get(opts, :skip_dirs, @skip_dirs)
      max_entries = Keyword.get(opts, :max_entries, @max_entries)

      walk_dir(start, root, match_files, skip, max_entries, [])
      |> Enum.reverse()
    else
      # single-file walk: the file itself must pass — this is the same
      # check read_file does at its entry point
      if File.regular?(start) and path_allowed?(scope, start),
        do: [start],
        else: []
    end
  end

  # The single cond that must never be duplicated. Both lessons live
  # here as comments so the next editor reads them before editing.
  defp walk_dir(dir, root, match_files, skip, max_entries, acc) do
    if length(acc) >= max_entries do
      acc
    else
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.sort()
          |> Enum.reduce_while(acc, fn entry, acc ->
            if length(acc) >= max_entries do
              {:halt, acc}
            else
              {:cont, handle_entry(dir, entry, root, match_files, skip, max_entries, acc)}
            end
          end)

        {:error, _} ->
          acc
      end
    end
  end

  # DIRS: check scope BEFORE entering — a symlinked dir that resolves
  # outside must not be entered (loop/escape risk). FILES: check scope
  # BEFORE yielding — a symlinked file that resolves outside must not
  # even be listed.
  defp handle_entry(dir, entry, root, match_files, skip, max_entries, acc) do
    full = Path.join(dir, entry)

    cond do
      File.dir?(full) ->
        if skip_dir?(entry, skip) or not path_allowed?(%{root: root}, full) do
          acc
        else
          walk_dir(full, root, match_files, skip, max_entries, acc)
        end

      File.regular?(full) and path_allowed?(%{root: root}, full) ->
        if match_files == nil or match_files.(entry),
          do: [full | acc],
          else: acc

      true ->
        acc
    end
  end

  defp skip_dir?(name, skip) do
    String.starts_with?(name, ".") or MapSet.member?(skip, name)
  end

  @doc "Dir names never worth walking (build/vendor/tool artifacts)."
  def default_skip_dirs, do: @skip_dirs
end
