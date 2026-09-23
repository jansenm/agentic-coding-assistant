defmodule CodingAgent.Core.Tools.Grep do
  @moduledoc """
  Read-only content search tool (slice 2d), per the ROADMAP 2d design:
  line-numbered matches, capped results.

  **Delegates to ripgrep when available** (ADR 016): `rg` is a materially
  better engine (PCRE2, speed, built-in binary skipping), so when it is
  present and produces a clean result the tool uses it; otherwise the
  pure-Elixir walk runs unchanged (portability: a machine with no `rg` and
  no network to install one, and the fallback is always the reference
  behaviour).

  Containment is preserved under delegation:

    * the requested `path` is scope-checked *before* `rg` runs;
    * every returned path is re-checked physically against the scope, so
      no symlinked escape can be listed;
    * `--no-config` is mandatory — `RIPGREP_CONFIG_PATH` can carry a
      `--pre` command, i.e. arbitrary execution, so the environment must
      never be allowed to influence the invocation;
    * `rg` does not follow symlinks in traversal (verified), and the
      explicit-path case is caught by the pre-check.

  The Elixir path enforces containment via `CodingAgent.Core.Containment`
  (the ONE walk implementation). Binary files are skipped; hidden entries
  and `_build`/`deps`/`.git` are skipped in both paths.

  ## Engine agreement: one glob rule, one hidden rule

  `rg` filters by its own glob dialect and its own hidden defaults, and
  both differ from ours (measured): `--glob '*.ex'` made it list
  `.hidden.ex`, `--glob 'lib/**/*.ex'` answered a path-anchored question
  where this tool documents a NAME glob, `./lib/*.ex` matched nothing and
  an invalid glob printed an error on stdout. So `rg` is not given the
  caller's glob at all: it searches wide and every match is filtered by
  the reference rule (`Glob.file_match?/3` + `Containment.hidden_allowed?/2`).
  `rg` runs `--hidden` so that a search which NAMED a hidden entry
  (`glob: ".env.example"`, `path: ".github"`) can find it, and the walk
  asks for `:include_hidden` under the same naming test. Both engines
  therefore return the same set for every shape the tool documents — the
  test that pins it is `SearchDelegationTest` "engine agreement".
  """

  alias CodingAgent.Core.Containment
  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.External
  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.Glob

  @max_results 200
  @max_line_length 500
  @max_bytes 1024 * 1024

  # rg runs through the one executor (Exec + Sandbox), so the process is
  # confined like shell/git are. A search that outlives this bound falls
  # back to the reference engine rather than hanging the turn.
  @exec_timeout 60

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "grep",
      description:
        "Search file contents inside the session scope with a regular " <>
          "expression. Returns at most #{@max_results} matches " <>
          "as \"path:line: line text\". Skip binary files; ignores standard " <>
          "build/vendor directories. Use glob first to narrow files if needed.",
      parameter_schema: [
        pattern: [
          type: :string,
          required: true,
          doc: "Regular expression to search for"
        ],
        path: [
          type: :string,
          required: false,
          default: ".",
          doc:
            "File or directory to search (default: the scope root). " <>
              "Files outside the scope are rejected."
        ],
        glob: [
          type: :string,
          required: false,
          doc: "Only search files whose name matches this glob, e.g. \"*.ex\" or \"*.exs\""
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  def max_results, do: @max_results

  defp execute(scope, args) do
    pattern = Map.get(args, :pattern) || Map.get(args, "pattern")
    path = Map.get(args, :path) || Map.get(args, "path") || "."
    glob = Map.get(args, :glob) || Map.get(args, "glob")

    with :ok <- validate_pattern(pattern),
         :ok <- ensure_exists(scope, path),
         :ok <- check_in_scope_path(scope, path) do
      do_search(scope, pattern, path, glob)
    end
  end

  defp validate_pattern(pattern) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, _re} -> :ok
      {:error, {msg, _pos}} -> Tools.error("invalid regex #{inspect(pattern)}: #{msg}")
    end
  end

  defp validate_pattern(_), do: Tools.error("pattern must be a non-empty string")

  defp ensure_exists(scope, path) do
    abs = abs_path(scope, path)

    cond do
      File.regular?(abs) or File.dir?(abs) -> :ok
      true -> Tools.error("no such file or directory: #{inspect(path)}")
    end
  end

  defp check_in_scope_path(scope, path) do
    Containment.check_scope!(scope, path)
  end

  # -- Engine selection (ADR 016) ---------------------------------------------

  defp do_search(scope, pattern, path, glob) do
    case External.probe(:rg) do
      {:ok, rg} ->
        case rg_search(rg, scope, pattern, path, glob) do
          {:ok, _} = ok -> ok
          # rg failed for a reason that is not "no matches" (e.g. a
          # pattern Elixir's regex accepts but its PCRE2 rejects): fall
          # back to the reference implementation rather than report an
          # engine-specific error.
          :fallback -> elixir_search(scope, pattern, path, glob)
        end

      :error ->
        elixir_search(scope, pattern, path, glob)
    end
  end

  # -- ripgrep delegation ------------------------------------------------------

  defp rg_search(rg, scope, pattern, path, glob) do
    root = Path.expand(scope.root)
    target = rel_target(root, path)

    # --hidden so a search that NAMED a hidden entry can see it; the
    # result is filtered by the same naming test below, so nothing
    # else gains hidden entries (see moduledoc).
    args =
      ["--json", "--no-config", "--no-ignore", "--color=never", "--max-filesize", "1M"] ++
        ["--hidden"] ++
        exclude_args(target) ++
        ["-e", pattern, "--", target]

    # The command runs through Exec under the sandbox profile, exactly
    # like shell/git. read_only/1 builds the profile; a confining
    # sandbox bounds the process (no writes, no network), and the scope
    # is already mountable, so delegation needs nothing else.
    profile = scope |> Tools.profile() |> Map.put(:root, root)

    case Exec.run({:exec, rg, args}, root, @exec_timeout, profile) do
      {:ok, out, 0} -> format_rg_matches(out, root, glob, path)
      # exit 1 is "no match" for rg (unlike fd, where 1 is an error —
      # measured); anything else is a failed run we do not want to show.
      {:ok, out, 1} -> format_rg_matches(out, root, glob, path)
      _ -> :fallback
    end
  end

  # The caller's glob is NOT handed to rg: its dialect is close but not
  # ours (measured — `lib/**/*.ex` matched a path-anchored pattern,
  # `./lib/*.ex` matched nothing, an invalid glob printed an error on
  # stdout), and an include filter that is narrower than our rule would
  # silently DROP matches the reference engine finds. So rg searches wide
  # and the result is filtered by the reference rule; the skip trees are
  # still pruned in the invocation, which is what keeps the search cheap.
  #
  # The named target is exempt from its OWN name's exclusion: naming a
  # path is the opt-in (the walk enters a named `doc`/`.git`, it only
  # prunes such entries it meets on the way) — `path: "src/doc"` must
  # search it in both engines.
  defp exclude_args(target) do
    named = Path.basename(target)

    External.skip_dirs()
    |> Enum.reject(&(&1 == named))
    |> Enum.flat_map(fn dir -> ["--glob", "!**/#{dir}/**"] end)
  end

  # rg walks in its own order; the reference engine walks sorted. One
  # deterministic order for both (`path`, then `line`: also the natural
  # reading order), so the two engines are comparable and a diff of two
  # runs is empty.
  defp format_rg_matches(out, root, glob, path) do
    names = [glob, path]

    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&rg_match_line(&1, root))
    |> Enum.filter(&keep_match?(&1, names))
    |> Enum.sort()
    |> Enum.take(@max_results)
    |> format_results()
  end

  # One match survives when the caller's glob accepts its path (the same
  # `Glob.file_match?/3` the `glob` tool uses) and the hidden rule allows
  # it. Both engines therefore return the same set.
  defp keep_match?({rel, _line, _text}, names) do
    Containment.hidden_allowed?(rel, names) and glob_accepts?(List.first(names), rel)
  end

  defp glob_accepts?(nil, _rel), do: true
  defp glob_accepts?(glob, rel), do: Glob.file_match?(glob, rel, Path.basename(rel))

  defp rg_match_line(line, root) do
    with {:ok, %{"type" => "match", "data" => data}} <- Jason.decode(line),
         %{"path" => %{"text" => path}, "line_number" => n, "lines" => %{"text" => text}} <- data,
         abs = Path.expand(path, root),
         true <- Tools.in_scope?(%{root: root}, abs) do
      [{Path.relative_to(abs, root), n, clip(String.trim_trailing(text, "\n"))}]
    else
      _ -> []
    end
  end

  defp rel_target(root, path) do
    abs = abs_path(%{root: root}, path)
    Path.relative_to(abs, root)
  end

  # -- pure-Elixir reference implementation ------------------------------------

  defp elixir_search(scope, pattern, path, glob) do
    re = Regex.compile!(pattern)
    root = Path.expand(scope.root)
    {files, explicit?} = collect_files(scope, path, glob)

    results =
      files
      |> Enum.flat_map(fn file ->
        case search_file(re, file) do
          # oversized/binary files in a walk are noise; only an explicit
          # single-file search gets a diagnostic
          :skip ->
            []

          :too_big ->
            if explicit?,
              do: [{rel(root, file), -1, "(file larger than 1 MiB, skipped)"}],
              else: []

          lines ->
            Enum.map(lines, fn {file, line, text} -> {rel(root, file), line, text} end)
        end
      end)
      # the SAME report rule and the SAME order as the rg path
      # (see keep_match?/2 + format_rg_matches/4)
      |> Enum.filter(&keep_match?(&1, [glob, path]))
      |> Enum.sort()
      |> Enum.take(@max_results)

    format_results(results)
  end

  defp format_results(results) do
    total = length(results)

    truncated =
      if total == @max_results,
        do: "\n[... capped at #{total} matches; narrow the pattern or path ...]\n",
        else: ""

    body =
      results
      |> Enum.map(fn {file, line, text} -> "#{file}:#{line}:#{text}" end)
      |> Enum.join("\n")

    {:ok, body <> truncated}
  end

  # Files to search: a single explicit file, or a containment-respecting
  # walk of the target directory (Containment owns the discipline). The
  # second element says whether the caller named one file — it decides
  # whether an oversized file is reported or silently skipped.
  defp collect_files(scope, path, glob) do
    start = abs_path(scope, path)

    if File.regular?(start) do
      {Containment.walk(scope, path), true}
    else
      match_files =
        if glob do
          fn name, rel -> Glob.file_match?(glob, rel, name) end
        end

      walk =
        Containment.walk(scope, path,
          match_files: match_files,
          include_hidden: Containment.hidden_pattern?(glob || path)
        )

      {walk, false}
    end
  end

  defp search_file(re, file) do
    case File.read(file) do
      {:ok, bytes} when byte_size(bytes) > @max_bytes ->
        :too_big

      {:ok, bytes} ->
        if printable?(bytes) do
          bytes
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {line, n} ->
            if Regex.match?(re, line), do: [{file, n, clip(line)}], else: []
          end)
        else
          :skip
        end

      {:error, _} ->
        :skip
    end
  rescue
    # unreadable or invalid-UTF-8 files are not grep targets
    _ -> :skip
  end

  defp printable?(bytes) do
    sample = binary_part(bytes, 0, min(byte_size(bytes), 1000))
    # NUL byte is the cheap binary detector
    :binary.match(sample, <<0>>) == :nomatch
  end

  defp clip(line) do
    if String.length(line) <= @max_line_length do
      line
    else
      String.slice(line, 0, @max_line_length) <> "..."
    end
  end

  defp abs_path(scope, path), do: Path.expand(path, Path.expand(scope.root))

  defp rel(root, file), do: Path.relative_to(file, root)
end
