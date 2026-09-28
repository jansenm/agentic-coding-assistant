defmodule CodingAgent.Core.Containment do
  @moduledoc """
  The DISCOVERY discipline for filesystem walks (ADR 010 lessons; role
  changed by ADR 030).

  One rule, encoded in one place so walkers cannot re-forget it:

  > In a filesystem walk, **every** entry — file *or* directory —
  > passes the scope check before it is used. A symlinked directory
  > pointing outside the scope is a walkable escape (slice 2d bug #1);
  > a symlinked file pointing out is a listing/read leak (slice 2d
  > bug #2). Both variants of the same mistake.

  **ADR 030: this is no longer a security boundary.** The sandbox
  profile enforces reach; the native file tools run as confined
  processes and `grep`/`glob` delegate to confined `rg`/`fd`. What
  remains here is *discovery*: a walk that lists what exists inside the
  scope (for a picker or an autocomplete), a scope predicate for
  filtering and anchoring, and the hidden-entry vocabulary both engines
  share. Nothing may rely on these for enforcement.

  Consumers:

  - `path_allowed?/2` — the single-path scope predicate (physical
    symlink resolution included). Discovery/filtering, not enforcement.
  - `walk/3` — the scope-respecting directory walk (used by a discovery
    feature, not by the search tools any more).
  - `default_skip_dirs/0` — the shared build/vendor/hidden skip list.
  - `hidden_entry?/1` / `hidden_pattern?/1` — THE hidden rule (below),
    still applied to `rg`/`fd` output.

  ## The hidden rule

  Hidden entries are a DISCOVERY default, not a boundary: they are
  noise in a search result, and the way back is to *name* them.

    * `hidden_entry?/1` decides what counts as hidden for a path (any
      segment starting with a dot) — one definition, so `fd`'s path and
      any walk cannot disagree. It covers FILES and DIRS alike:
      `fd` skips a hidden file exactly as it skips a hidden dir, so a
      plain `grep`/`glob` must not return dotfiles it never returned
      (measured: 5 files of difference on this repo).
    * `hidden_pattern?/1` decides whether a glob pattern or a named
      path asks for a hidden entry (`.gitignore`, `.*`, `.idea/*`,
      `**/.gitconfig`). That is the opt-in, and it is POSIX spelling
      (`ls .*`, `cat .gitignore`), not a new vocabulary.
    * `filter_hidden/2` applies the rule to an engine's result list.

  Containment is untouched by this: it is about the scope root, and the
  same hidden file is reachable by name through `read_file` either way
  (naming is the opt-in at every layer).
  """

  alias CodingAgent.Core.Tools

  @skip_dirs MapSet.new(["_build", "deps", ".git", "doc", "cover", ".elixir_ls"])

  @max_entries 2000

  @typedoc "Options for `walk/3`."
  @type walk_opt ::
          {:match_files, (String.t() -> boolean())}
          | {:skip_dirs, MapSet.t()}
          | {:max_entries, pos_integer()}
          | {:include_hidden, boolean()}

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

    - `:match_files` — `fn name, rel_path -> boolean end`, applied to the
      entry NAME and to its path relative to the SCOPE ROOT (the two
      shapes a tool documents: `*.ex` and `lib/**/*.ex`).
    - `:skip_dirs` — extra dir names to prune (defaults from
      `default_skip_dirs/0`).
    - `:max_entries` — walk budget; the walk stops adding once hit
      (breadth over the file entries already collected).
    - `:include_hidden` — the caller asked for hidden entries by name
      (see `hidden_pattern?/1`): hidden dirs are descended into and
      hidden files are yielded. Default false, which is what makes the
      walk agree with `rg`/`fd` (both skip hidden entries by default).

  Either way, a path NAMED as the walk's start is used as given: the
  single-file branch below yields a hidden file, and a hidden dir is
  entered. That is the same opt-in as `read_file .gitignore` — naming
  beats filtering at every layer.

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
      hidden = Keyword.get(opts, :include_hidden, false)

      walk_dir(start, root, match_files, skip, hidden, max_entries, [])
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
  defp walk_dir(dir, root, match_files, skip, hidden, max_entries, acc) do
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
              {:cont, handle_entry(dir, entry, root, match_files, skip, hidden, max_entries, acc)}
            end
          end)

        {:error, _} ->
          acc
      end
    end
  end

  # DIRS: check scope BEFORE entering — a symlinked dir that resolves
  # outside must not be entered (loop/escape risk), and skip it if it is
  # noise (hidden unless opted in, build/vendor always).
  # FILES: the HIDDEN rule applies (`fd` and `rg` skip a hidden file
  # exactly as they skip a hidden dir — that is what makes the engines
  # agree), but the build/vendor list does NOT: it names *directories*
  # ("dir names never worth walking"), and a file that happens to be
  # called `cover` is a file. Then the scope check BEFORE yielding — a
  # symlinked file that resolves outside must not even be listed.
  defp handle_entry(dir, entry, root, match_files, skip, hidden, max_entries, acc) do
    full = Path.join(dir, entry)

    cond do
      File.dir?(full) ->
        if skip_dir?(entry, skip, hidden) or not path_allowed?(%{root: root}, full) do
          acc
        else
          walk_dir(full, root, match_files, skip, hidden, max_entries, acc)
        end

      File.regular?(full) and path_allowed?(%{root: root}, full) ->
        if not hidden?(entry, hidden) and match_file?(match_files, entry, full, root),
          do: [full | acc],
          else: acc

      true ->
        acc
    end
  end

  # The file filter, called with the entry NAME and its path RELATIVE TO
  # THE SCOPE ROOT — the two shapes a tool's glob documents (`*.ex` and
  # `lib/**/*.ex`). No filter means "take everything".
  defp match_file?(nil, _entry, _full, _root), do: true

  defp match_file?(match_files, entry, full, root),
    do: match_files.(entry, Path.relative_to(full, root))

  # THE dir skip test: the hidden rule (unless the caller opted in) plus
  # the shared build/vendor list.
  defp skip_dir?(name, skip, hidden) do
    hidden?(name, hidden) or MapSet.member?(skip, name)
  end

  defp hidden?(name, hidden), do: not hidden and String.starts_with?(name, ".")

  @doc "Dir names never worth walking (build/vendor/tool artifacts)."
  def default_skip_dirs, do: @skip_dirs

  @doc """
  Whether an entry name or a path is hidden — any `"/"`-separated
  segment starting with a dot. THE definition; `fd`'s path and the walk
  both filter with it, so the two engines cannot disagree.

  (It is deliberately stricter than `fd`'s own skip rule: `fd` also
  hides gitignored entries, which would silently drop
  `.github/workflows/ci.yml` from a `*.yml` search. Measured.)
  """
  @spec hidden_entry?(String.t()) :: boolean()
  def hidden_entry?(path) do
    path
    |> String.split("/")
    |> Enum.any?(&hidden_segment?/1)
  end

  @doc """
  Whether a glob PATTERN or a named path opts in to hidden entries —
  the caller's request, in POSIX spelling (`ls .*`, `cat .gitignore`).
  True when a segment NAMES a hidden entry: `.gitignore`, `.*`,
  `.idea/*`, `**/.gitconfig`, `docs/.gitkeep`, or a path like
  `.github`.

  A `**` segment is a wildcard, not a name, so it does not opt in:
  `**/.gitkeep` does (the `.gitkeep` segment does), `**/*` does not.
  Neither do `.` and `..`, which are path syntax.
  """
  @spec hidden_pattern?(String.t()) :: boolean()
  def hidden_pattern?(pattern) do
    pattern
    |> String.split("/")
    |> Enum.any?(&hidden_segment?/1)
  end

  # ONE hidden test, for entries and for patterns: a leading dot that is
  # a name, not `.`/`..`.
  defp hidden_segment?(segment) do
    String.starts_with?(segment, ".") and segment not in [".", ".."]
  end

  @doc """
  The hidden rule applied to a result list: a search that did not NAME a
  hidden entry gets no hidden entries, however the engine that produced
  them behaves (`fd --hidden`, `rg --hidden`, or a walk with
  `:include_hidden`). One filter for every engine, so naming stays the
  only thing the caller has to remember.

  `names` are everything the caller said about *what* to search — a glob
  pattern, a `path` argument, or both (`[glob, path]`); `nil` entries
  carry no naming.
  """
  @spec filter_hidden([String.t()], [String.t() | nil]) :: [String.t()]
  def filter_hidden(entries, names) do
    Enum.filter(entries, &hidden_allowed?(&1, names))
  end

  @doc """
  Whether one result may be reported: it is either not hidden, or the
  caller NAMED a hidden entry somewhere ({@link hidden_opt_in?/1}).
  The single predicate behind `filter_hidden/2`.
  """
  @spec hidden_allowed?(String.t(), [String.t() | nil]) :: boolean()
  def hidden_allowed?(entry, names) do
    hidden_opt_in?(names) or not hidden_entry?(entry)
  end

  @doc """
  Whether the caller named a hidden entry anywhere — THE opt-in test for
  a search, however many names it carries. `nil` entries are ignored, so
  `[nil, "."]` is the plain "nothing named" case.
  """
  @spec hidden_opt_in?([String.t() | nil]) :: boolean()
  def hidden_opt_in?(names) do
    Enum.any?(names, &(is_binary(&1) and hidden_pattern?(&1)))
  end
end
