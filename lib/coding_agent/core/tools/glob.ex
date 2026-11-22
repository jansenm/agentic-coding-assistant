# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.Glob do
  @moduledoc """
  Read-only filename search tool (slice 2d): glob patterns over the
  scope, sorted, capped.

  **Delegates to `fd`** (ADR 016). ADR 030 made the external engine
  REQUIRED: the pure-Elixir walk was a second, unconfined boundary (a
  BEAM walk that ignored `hide`/`ro`/`root_ro`). When `fd` is absent the
  tool refuses with a clear error naming the dependency; there is no
  unconfined search.

  ## The dialect

  `**` spans zero or more segments, `*`/`?` are per-segment, `{a,b}`
  braces expand. "Same dialect in both paths" is a CONTRACT, not a
  hope, and the reference engine (`Core.GlobMatch`) defines it. `fd`'s
  dialect is RICHER than ours in a few measured places, so a pattern
  using one of those is not handed to fd at all:

    * `[...]` classes, a leading `!` as negation, `\\` as a quote —
      ours reads them literally (`[ab].ex` listed `a.ex`+`b.ex` under
      fd's class, nothing under ours);
    * shapes that are not a plain scope-relative path (`/x`, `./x`,
      `x/`, `a//b`) — fd normalizes them its own way (`**/` matched
      every file).

  Such a pattern uses fd's WIDE enumeration (`--glob '*'` with a
  bounded result budget), and the reference rule filters every
  candidate — one filter, so the answer is ours, not fd's. A
  dialect-clean pattern is passed to fd directly (anchored at the root
  when it contains a `/`) and the result is STILL filtered by the same
  rule, so the two branches cannot disagree.

  A non-zero exit is treated as a failure, so an engine error is refused
  rather than shown to the model as a result.

  ## Hidden entries: a default, not a wall

  Hidden entries are skipped, and the way to ask for them is to NAME
  them (`Containment.hidden_pattern?/1`) — `.gitignore`, `.*`,
  `.idea/*`. The caller's pattern is the opt-in; there is nothing else
  to remember. `fd` is invoked with `--hidden` so the opt-in pattern can
  match, and the result is filtered afterwards, so a pattern that did
  NOT ask for hidden entries cannot get them.

  Build/vendor trees (`_build`, `deps`, …) are pruned by `fd --exclude`.

  Containment is preserved: `fd` is run with `--no-ignore` (our skip
  rules, not the repo's, decide), under the session profile through
  `Exec`; every returned path is re-checked physically against the
  scope, so an out-of-scope symlink can never be listed.
  """

  alias CodingAgent.Core.Containment
  alias CodingAgent.Core.External
  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.FdSearch

  @max_results 500

  # The wide enumeration is NOT capped. A cap on `fd`'s output is applied
  # BEFORE the reference filter, so the filter would see only an
  # arbitrary slice and silently drop real matches (review F1: with 6001
  # files and `--max-results 2000`, `glob "[a]*needle*"` found nothing
  # while `glob "*needle*"` found the file). The engine enumerates, the
  # ONE reference rule filters, and the 500-result cap is applied AFTER
  # the filter (`format_matches/1`) — where its "capped" note is true.
  # The 60s `Exec` timeout is the bound on the enumeration.

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "glob",
      description:
        "Find files inside the session scope by glob pattern (e.g. " <>
          "\"lib/**/*.ex\", \"*.{ex,exs}\" or \"Makefile\"). Returns matching " <>
          "paths sorted. Hidden and build/vendor directories are skipped — " <>
          "name a hidden path (e.g. \".github/*\") to search it. " <>
          "Use before grep/read_file to locate files.",
      parameter_schema: [
        pattern: [
          type: :string,
          required: true,
          doc: "Glob relative to the scope root, e.g. \"lib/**/*.ex\" or \"**/*.toml\""
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  def max_results, do: @max_results

  defp execute(scope, args) do
    pattern = Map.get(args, :pattern) || Map.get(args, "pattern")

    with :ok <- validate(pattern) do
      do_match(scope, pattern)
    end
  end

  defp validate(pattern) when is_binary(pattern) and pattern != "", do: :ok
  defp validate(_), do: Tools.error("pattern must be a non-empty string")

  # -- fd delegation (ADR 016/030/032) -----------------------------------------

  defp do_match(scope, pattern) do
    root = Path.expand(scope.root)

    case FdSearch.run(scope, fd_args(root, pattern)) do
      {:ok, out} -> format_fd_matches(out, root, pattern)
      {:error, reason} -> Tools.error(FdSearch.error_message(reason))
    end
  end

  # Whether fd reads the pattern exactly as the reference dialect does.
  # False for the measured divergences (see the moduledoc): an exotic
  # pattern goes through the wide enumeration instead, so fd never gets
  # to reinterpret it.
  defp direct_pattern?(pattern) do
    pattern != "" and
      not String.starts_with?(pattern, ["!", "/", "./", "../"]) and
      not String.ends_with?(pattern, "/") and
      not String.contains?(pattern, ["\\", "[", "]", "//", "/./", "/../"])
  end

  defp fd_args(root, pattern) do
    if direct_pattern?(pattern) do
      # A pattern with a slash addresses a PATH; fd matches the entry NAME
      # unless --full-path is given, and then it matches the path fd
      # PRINTS, which must be absolute for the scope root to be the
      # anchor. Both flags together, pattern anchored at the root, make
      # fd agree with the reference engine (the "engine agreement" test).
      {flags, target} =
        if String.contains?(pattern, "/"),
          do: {["--absolute-path", "--full-path"], Path.join(root, pattern)},
          else: {[], pattern}

      # --hidden so an opting-in pattern can match (see moduledoc; the
      # result is filtered below, so nothing else gains hidden entries).
      # --case-sensitive because fd's default is smart case: it answered
      # "*.EX" case-insensitively where the reference engine does not.
      ["--glob", "--color=never", "--no-ignore", "--hidden", "--case-sensitive", "--type", "f"] ++
        flags ++
        exclude_args() ++
        [target, "."]
    else
      # Wide enumeration; the reference rule decides what is a match.
      # `--glob '*'` is the whole filter fd gets. NO `--max-results`:
      # capping here would hand the filter only a slice (review F1).
      ["--glob", "--color=never", "--no-ignore", "--hidden", "--case-sensitive", "--type", "f"] ++
        exclude_args() ++
        ["*", "."]
    end
  end

  # fd's --exclude is a glob matched against the whole path, and a bare
  # name prunes a FILE of that name too (measured: a file called `cover`
  # disappeared, because `default_skip_dirs/0` names *directories*).
  # `**/<dir>/**` prunes the directory subtree at any depth and leaves
  # same-named files alone — the reference rule. ONE builder in External,
  # shared with the `@`-picker (ADR 032).
  defp exclude_args, do: External.exclude_args()

  # The delegated result is filtered with the ONE reference rule
  # (`file_match?/3` + the hidden rule): fd decides nothing about the
  # caller's pattern; it enumerates or pre-filters, and this filter is
  # what makes "the pattern means one thing" true in code.
  defp format_fd_matches(out, root, pattern) do
    matches =
      out
      |> FdSearch.parse_paths(root)
      |> Enum.filter(&file_match?(pattern, &1, Path.basename(&1)))
      |> Containment.filter_hidden([pattern])
      |> Enum.take(@max_results)

    format_matches(matches)
  end

  defp format_matches(matches) do
    body = Enum.join(matches, "\n")

    suffix =
      if length(matches) == @max_results,
        do: "\n[... capped at #{@max_results} results; narrow the pattern ...]",
        else: ""

    {:ok, if(body == "", do: "(no matches)", else: body <> suffix)}
  end

  # -- Pure-string glob matching (Elixir 1.20 has no Path.match/2) -------
  # The matcher itself lives in Core.GlobMatch (the one dialect shared
  # with the permission layer). Glob adds brace expansion on top, a
  # search-time convenience the policy loader does not offer.

  alias CodingAgent.Core.GlobMatch

  @doc """
  Glob match against a path string: `**` spans segments (including
  zero), `*`/`?` are per-segment, `{a,b}` braces expand. Same dialect
  as the permission layer, plus braces.
  """
  def glob_match?(pattern, path) do
    pattern
    |> expand_braces()
    |> Enum.any?(&GlobMatch.match?(&1, path))
  end

  @doc """
  Whether a FILE matches the caller's glob — THE rule both search tools
  apply, so a pattern means the same thing in `glob` and in `grep`'s
  `glob` argument. The pattern is matched against the path relative to
  the scope root (`lib/**/*.ex`) and against the bare file name
  (`*.ex`) — the two shapes the tool documents.
  """
  @spec file_match?(String.t(), String.t(), String.t()) :: boolean()
  def file_match?(pattern, rel_path, name) do
    glob_match?(pattern, rel_path) or glob_match?(pattern, name)
  end

  defp expand_braces(pattern) do
    case Regex.run(~r/\{([^{}]+)\}/, pattern, capture: :all_but_first) do
      [body] ->
        Enum.flat_map(String.split(body, ","), fn alt ->
          expand_braces(String.replace(pattern, "{" <> body <> "}", alt))
        end)

      nil ->
        [pattern]
    end
  end
end
