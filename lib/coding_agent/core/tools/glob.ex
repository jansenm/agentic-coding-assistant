defmodule CodingAgent.Core.Tools.Glob do
  @moduledoc """
  Read-only filename search tool (slice 2d): glob patterns over the
  scope, sorted, capped.

  **Delegates to `fd` when available** (ADR 016), with the pure-Elixir
  walk as the reference fallback (portability, and `fd` may be absent).

  ## The dialect

  `**` spans zero or more segments, `*`/`?` are per-segment, `{a,b}`
  braces expand. "Same dialect in both paths" is a CONTRACT, not a
  hope, and the reference engine (`Core.GlobMatch`) defines it. Three
  measured divergences are closed in `fd_match/3`:

    * `fd` matches the entry NAME unless `--full-path` is given, so
      every pattern with a `/` goes to it ROOT-ANCHORED and absolute
      (`--absolute-path --full-path`, pattern `Path.join(root,
      pattern)`). Without that, `lib/**/*.ex` matched nothing while the
      Elixir path found 59 files;
    * `fd`'s smart case answers `*.EX` case-insensitively; the
      reference engine does not, so `fd` runs `--case-sensitive`;
    * `fd`'s dialect is RICHER than ours — it also reads `[...]`
      classes, a leading `!` as negation and `\` as a quote. A pattern
      using one of those asks a different question than the walk
      answers (`[ab].ex` listed `a.ex`+`b.ex` under `fd`, nothing in the
      walk; measured), so `fd_dialect?/1` keeps it on the reference
      engine. Same for shapes that are not a plain scope-relative path
      (`/x`, `./x`, `x/`, `a//b`): `fd` normalizes those its own way
      (`**/` matched every file).

  A non-zero exit is always treated as a failure (fd reports "no
  matches" with exit 0 — the 0/1 convention belongs to its `--quiet`
  flag; measured), so an engine error falls back instead of being shown
  to the model as a result.

  ## Hidden entries: a default, not a wall

  Hidden entries are skipped, and the way to ask for them is to NAME
  them (`Containment.hidden_pattern?/1`) — `.gitignore`, `.*`,
  `.idea/*`. The caller's pattern is the opt-in; there is nothing else
  to remember. `fd` is invoked with `--hidden` so the opt-in pattern can
  match, and the result is filtered afterwards, so a pattern that did
  NOT ask for hidden entries cannot get them (without that filter
  `--hidden` would be a net widening — `**/*` would start listing
  dotfiles it never listed before).

  Build/vendor trees (`_build`, `deps`, …) are pruned by `fd --exclude`
  and by the walk's skip list.

  Containment is preserved: `fd` is run with `--no-ignore` (our skip
  rules, not the repo's, decide); every returned path is re-checked
  physically against the scope, so an out-of-scope symlink can never be
  listed. The pure-Elixir path enforces the same via
  `CodingAgent.Core.Containment` (the ONE walk implementation).
  """

  alias CodingAgent.Core.Containment
  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.External
  alias CodingAgent.Core.Tools

  @max_results 500

  # fd runs through the one executor (Exec + Sandbox), like grep's rg. A
  # search that outlives this bound falls back to the reference walk.
  @exec_timeout 60

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

  defp do_match(scope, pattern) do
    case External.probe(:fd) do
      {:ok, fd} ->
        case fd_match(fd, scope, pattern) do
          {:ok, _} = ok -> ok
          :fallback -> elixir_match(scope, pattern)
        end

      :error ->
        elixir_match(scope, pattern)
    end
  end

  # -- fd delegation -----------------------------------------------------------

  defp fd_match(fd, scope, pattern) do
    if fd_dialect?(pattern) do
      root = Path.expand(scope.root)

      # Same confined-process path as grep: run fd through Exec under the
      # read-only sandbox profile instead of a bare System.cmd.
      profile = scope |> Tools.profile() |> Map.put(:root, root)

      case Exec.run({:exec, fd, fd_args(root, pattern)}, root, @exec_timeout, profile) do
        # 0 is the only success code: fd reports "no matches" with exit 0
        # (the 0/1 convention belongs to --quiet; measured), so a 1 here
        # is an error — whose text would otherwise reach the model as a
        # tool result, because Exec collects stderr into stdout.
        {:ok, out, 0} -> format_fd_matches(out, root, pattern)
        _ -> :fallback
      end
    else
      :fallback
    end
  end

  # Where fd would answer a DIFFERENT question, the reference engine
  # answers instead (see moduledoc). Every clause is a measured
  # divergence, in fd's own language:
  #
  #   * `[...]` / `\` — fd reads a character class / a quote, our
  #     dialect reads literals (`[ab].ex` matched a.ex+b.ex under fd);
  #   * a leading `!` — fd reads negation (`!*` listed everything);
  #   * `/x`, `./x`, `x/`, `a//b` — not a plain scope-relative path; fd
  #     normalizes them its own way (`**/` matched every file, `/lib/*.ex`
  #     was silently re-anchored).
  defp fd_dialect?(pattern) do
    pattern != "" and
      not String.starts_with?(pattern, ["!", "/", "./", "../"]) and
      not String.ends_with?(pattern, "/") and
      not String.contains?(pattern, ["\\", "[", "]", "//", "/./", "/../"])
  end

  defp fd_args(root, pattern) do
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
  end

  # fd's --exclude is a glob matched against the whole path, and a bare
  # name prunes a FILE of that name too (measured: a file called `cover`
  # disappeared while the walk keeps it, because `default_skip_dirs/0`
  # names *directories*). `**/<dir>/**` prunes the directory subtree at
  # any depth and leaves same-named files alone — the walk's rule.
  defp exclude_args do
    Enum.flat_map(External.skip_dirs(), fn dir -> ["--exclude", "**/#{dir}/**"] end)
  end

  # The delegated result is re-filtered with the SAME rule the reference
  # engine applies (`file_match?/3` + the hidden rule): fd decides by its
  # own dialect and its own hidden defaults, and this makes "the pattern
  # means one thing" true in code, not just in measurement.
  defp format_fd_matches(out, root, pattern) do
    matches =
      out
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim_leading(&1, "./"))
      |> Enum.map(&Path.expand(&1, root))
      |> Enum.filter(&Tools.in_scope?(%{root: root}, &1))
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.filter(&file_match?(pattern, &1, Path.basename(&1)))
      |> Containment.filter_hidden([pattern])
      |> Enum.sort()
      |> Enum.take(@max_results)

    format_matches(matches)
  end

  # -- pure-Elixir reference implementation ------------------------------------

  defp elixir_match(scope, pattern) do
    root = Path.expand(scope.root)

    matches =
      Containment.walk(scope, ".", include_hidden: Containment.hidden_pattern?(pattern))
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.filter(&file_match?(pattern, &1, Path.basename(&1)))
      |> Enum.sort()
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
