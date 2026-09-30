defmodule CodingAgent.Core.Tools.ListFiles do
  @moduledoc """
  The repo-file list for the `@`-file picker (ADR 032).

  This is not a tool the model calls: it is the TUI's confined
  enumeration behind the `@` trigger. `list/1` runs ``fd`` through
  `Tools.FdSearch` (so the sandbox profile, the shared skip list and the
  physical scope re-check all apply) and returns every file — hidden ones
  INCLUDED, because the hidden rule depends on the query the user types.

  `filter/2` applies the ONE hidden rule (``Containment.hidden_allowed?/2``)
  for the current query plus a case-insensitive substring match, so a
  plain query offers exactly what ``glob`` would report and naming a
  hidden segment (``@.github``) opts in — no second vocabulary. The list
  is fetched once when the popup opens; filtering is in-memory.

  A missing ``fd`` is `{:error, :fd_unavailable}`; the caller shows a
  note rather than opening an empty, lying list.
  """

  alias CodingAgent.Core.Containment
  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.FdSearch

  # The picker wants every file and filters in memory, so it must not ask
  # `fd` for a bounded result: a cap applied here (before the query
  # filter) silently dropped matching files from the popup (review F4).
  # The 60s `Exec` timeout bounds the enumeration instead. Output is
  # parsed untruncated (`FdSearch.run`), so no banner can become a file.
  @doc """
  Lists every file in `scope` (relative paths, sorted), hidden included.

  Returns `{:ok, files}`; no silent cap is applied. `fd` errors are
  explicit (`{:error, reason}`), never an empty list.
  """
  @spec list(Tools.scope()) :: {:ok, [String.t()]} | {:error, term()}
  def list(scope) do
    root = Path.expand(scope.root)

    case FdSearch.run(scope, fd_args()) do
      {:ok, out} -> {:ok, FdSearch.parse_paths(out, root)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The files visible for `query`: those the hidden rule allows for the
  query's naming, narrowed by a case-insensitive substring match on the
  path.

  Convenience wrapper over `prepare/1` + `filter_prepared/2` for callers
  that hold only the raw list; the picker prepares once and reuses the
  index per keystroke.
  """
  @spec filter([String.t()], String.t()) :: [String.t()]
  def filter(files, query), do: filter_prepared(prepare(files), query)

  @doc """
  Precomputes the per-file index the filter needs — the downcased path
  and whether the file is hidden — ONCE, in the fetch task.

  Both facts are query-INDEPENDENT, so computing them per keystroke was
  pure waste: `hidden_entry?/1` splits the path on every call and every
  path was downcased on every character typed. Measured on 40k files this
  drops a keystroke filter from ~130ms to ~20ms (review F4).
  """
  @spec prepare([String.t()]) :: [{String.t(), String.t(), boolean()}]
  def prepare(files) do
    Enum.map(files, fn path ->
      {path, String.downcase(path), Containment.hidden_entry?(path)}
    end)
  end

  @doc """
  The prepared filter (`prepare/1` output) for `query`. Same result as
  `filter/2`; only the hidden OPT-IN depends on the query, so it is the
  one thing recomputed per keystroke.
  """
  @spec filter_prepared([{String.t(), String.t(), boolean()}], String.t()) :: [String.t()]
  def filter_prepared(prepared, query) do
    needle = String.downcase(query)
    opt_in = Containment.hidden_pattern?(query)

    for {path, low, hidden?} <- prepared,
        (not hidden? or opt_in) and String.contains?(low, needle),
        do: path
  end

  @doc "The user-facing message for a `list/1` error."
  @spec error_message(term()) :: String.t()
  def error_message(:fd_unavailable),
    do: "file list unavailable: fd was not found on PATH (install fd-find)"

  def error_message(reason), do: FdSearch.error_message(reason)

  # Wide enumeration, unbounded: the picker wants every file, then
  # filters in memory. `--hidden` so a named hidden entry can appear (the
  # hidden rule then decides); `--no-ignore` because OUR skip list
  # decides, not the repo's ignore files (the same choice glob makes).
  # No `--max-results` — see `list/1`.
  defp fd_args do
    ["--color=never", "--no-ignore", "--hidden", "--type", "f"] ++
      CodingAgent.Core.External.exclude_args() ++
      ["."]
  end
end
