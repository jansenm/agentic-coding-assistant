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
  (the ONE walk implementation). Binary files are skipped; hidden dirs and
  `_build`/`deps`/`.git` are skipped in both paths.
  """

  alias CodingAgent.Core.Containment
  alias CodingAgent.Core.External
  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.Glob

  @max_results 200
  @max_line_length 500
  @max_bytes 1024 * 1024

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

    args =
      ["--json", "--no-config", "--no-ignore", "--color=never", "--max-filesize", "1M"] ++
        include_args(glob) ++
        exclude_args() ++
        ["-e", pattern, "--", target]

    case System.cmd(rg, args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> format_rg_matches(out, root)
      {out, 1} -> format_rg_matches(out, root)
      {_out, _code} -> :fallback
    end
  rescue
    _ -> :fallback
  end

  # An include glob must precede the excludes: rg lets a later include
  # re-add what an earlier exclude removed (verified), so exclusions go
  # last to stay authoritative.
  defp include_args(nil), do: []

  defp include_args(glob) when is_binary(glob) and glob != "",
    do: ["--glob", glob]

  defp include_args(_), do: []

  # Skip the same build/vendor trees the Elixir walk skips. `**/` so a
  # nested `src/_build` is pruned too (a bare name would leak it — the
  # walk prunes at any depth).
  defp exclude_args do
    Enum.flat_map(External.skip_dirs(), fn dir -> ["--glob", "!**/#{dir}/**"] end)
  end

  defp format_rg_matches(out, root) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&rg_match_line(&1, root))
    |> Enum.take(@max_results)
    |> format_results()
  end

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

    files = collect_files(scope, path, glob)

    results =
      files
      |> Enum.flat_map(fn file ->
        case search_file(re, file) do
          # oversized/binary files in a walk are noise; only an explicit
          # single-file search gets a diagnostic
          :skip ->
            []

          :too_big ->
            if explicit_file?(path, file),
              do: [{rel(root, file), -1, "(file larger than 1 MiB, skipped)"}],
              else: []

          lines ->
            lines
        end
      end)
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
  # walk of the target directory (Containment owns the discipline).
  defp collect_files(scope, path, glob) do
    start = abs_path(scope, path)

    if File.regular?(start) do
      Process.put({__MODULE__, :explicit_file}, true)
      Containment.walk(scope, path)
    else
      Process.put({__MODULE__, :explicit_file}, false)

      match_files =
        if glob do
          fn name ->
            # name-only match, or a deeper glob like "**/*.ex"
            Glob.glob_match?(glob, name) or Glob.glob_match?(glob, "**/" <> name)
          end
        end

      Containment.walk(scope, path, match_files: match_files)
    end
  end

  defp explicit_file?(_path, _file) do
    Process.get({__MODULE__, :explicit_file}, false)
  end

  # (explicit_file flag is per-call process state; the tool callback
  # always runs in a single process, so no cross-talk in v1)

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
