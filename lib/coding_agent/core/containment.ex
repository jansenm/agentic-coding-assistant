defmodule CodingAgent.Core.Containment do
  @moduledoc """
  The shared hidden-entry vocabulary and skip list (ADR 010 lessons;
  role changed by ADR 030).

  **ADR 030: this is no longer a security boundary.** The sandbox
  profile enforces reach; the native file tools run as confined
  processes and `grep`/`glob` delegate to confined `rg`/`fd`. What
  remains here is *discovery* vocabulary: the build/vendor skip list
  both engines share, and the hidden rule both engines' output is
  filtered with. Nothing may rely on these for enforcement. The
  single-path scope predicate is `Tools.in_scope?/2`.

  Consumers:

  - `default_skip_dirs/0` — the shared build/vendor/hidden skip list.
  - `hidden_entry?/1` / `hidden_pattern?/1` — THE hidden rule (below),
    applied to `rg`/`fd` output.

  ## The hidden rule

  Hidden entries are a DISCOVERY default, not a boundary: they are
  noise in a search result, and the way back is to *name* them.

    * `hidden_entry?/1` decides what counts as hidden for a path (any
      segment starting with a dot) — one definition, so `fd`'s path and
      `rg`'s output cannot disagree. It covers FILES and DIRS alike:
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

  @skip_dirs MapSet.new(["_build", "deps", ".git", "doc", "cover", ".elixir_ls"])

  @doc "Dir names never worth walking (build/vendor/tool artifacts)."
  def default_skip_dirs, do: @skip_dirs

  @doc """
  Whether an entry name or a path is hidden — any `"/"`-separated
  segment starting with a dot. THE definition; `fd`'s path and `rg`'s
  output are both filtered with it, so the two engines cannot disagree.

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
  them behaves (`fd --hidden`, `rg --hidden`). One filter for every
  engine, so naming stays the only thing the caller has to remember.

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
  caller NAMED a hidden entry somewhere. The single predicate behind
  `filter_hidden/2`; `grep` filters with it directly.
  """
  @spec hidden_allowed?(String.t(), [String.t() | nil]) :: boolean()
  def hidden_allowed?(entry, names) do
    hidden_opt_in?(names) or not hidden_entry?(entry)
  end

  # Whether the caller named a hidden entry anywhere — THE opt-in test for
  # a search, however many names it carries. `nil` entries are ignored, so
  # `[nil, "."]` is the plain "nothing named" case.
  defp hidden_opt_in?(names) do
    Enum.any?(names, &(is_binary(&1) and hidden_pattern?(&1)))
  end
end
