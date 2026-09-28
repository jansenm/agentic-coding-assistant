defmodule CodingAgent.Core.Tools.Grep do
  @moduledoc """
  Read-only content search tool (slice 2d), per the ROADMAP 2d design:
  line-numbered matches, capped results.

  **Delegates to ripgrep** (ADR 016): `rg` is a materially better engine
  (PCRE2, speed, built-in binary skipping). ADR 030 made it REQUIRED:
  the pure-Elixir fallback was a second, unconfined boundary (a BEAM walk
  that ignored `hide`/`ro`/`root_ro`), and one boundary is the whole
  point. When `rg` is missing or rejects a pattern, the tool returns a
  clear error naming the dependency — never an unconfined search.

  Containment is preserved under delegation:

    * the requested `path` is reachable only through the sandbox profile
      (`rg` runs through `Exec` under it);
    * every returned path is re-checked physically against the scope, so
      no symlinked escape can be listed;
    * `--no-config` is mandatory — `RIPGREP_CONFIG_PATH` can carry a
      `--pre` command, i.e. arbitrary execution, so the environment must
      never be allowed to influence the invocation;
    * `rg` does not follow symlinks in traversal (verified), and the
      explicit-path case is caught by the pre-check.

  ## One glob rule, one hidden rule

  `rg` filters by its own glob dialect and its own hidden defaults, and
  both differ from ours (measured): `--glob '*.ex'` made it list
  `.hidden.ex`, `--glob 'lib/**/*.ex'` answered a path-anchored question
  where this tool documents a NAME glob, `./lib/*.ex` matched nothing and
  an invalid glob printed an error on stdout. So `rg` is not given the
  caller's glob at all: it searches wide and every match is filtered by
  the reference rule (`Glob.file_match?/3` + `Containment.hidden_allowed?/2`).
  `rg` runs `--hidden` so that a search which NAMED a hidden entry
  (`glob: ".env.example"`, `path: ".github"`) can find it.
  """

  alias CodingAgent.Core.Containment
  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.External
  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.Glob

  @max_results 200
  @max_line_length 500

  # rg runs through the one executor (Exec + Sandbox), so the process is
  # confined like shell/git are.
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

    with :ok <- validate_pattern(pattern) do
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

  # -- Engine selection (ADR 016/030) -----------------------------------------

  defp do_search(scope, pattern, path, glob) do
    case External.probe(:rg) do
      {:ok, rg} ->
        rg_search(rg, scope, pattern, path, glob)

      :error ->
        Tools.error(
          "ripgrep (rg) is required for the grep tool and was not found on PATH; " <>
            "install ripgrep to enable content search"
        )
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
    # like shell/git. Tools.profile/1 builds the profile; a confining
    # sandbox bounds the process (no writes, no network), and the scope
    # is already mountable, so delegation needs nothing else.
    profile = scope |> Tools.profile() |> Map.put(:root, root)

    case Exec.run({:exec, rg, args}, root, @exec_timeout, profile) do
      # The target does not exist (or is out of the profile's reach):
      # rg's own diagnostic is the model-readable answer.
      {:ok, out, 2} when out != "" ->
        {:error, String.trim(out)}

      # exit 1 is "no match" for rg (unlike fd, where 1 is an error —
      # measured)
      {:ok, out, code} when code in [0, 1] ->
        format_rg_matches(out, root, glob, path)

      {:ok, out, _code} ->
        Tools.error("rg failed: #{String.trim(out)}")

      {:timeout, _partial} ->
        Tools.error("rg search timed out after #{@exec_timeout}s")

      {:sandbox_error, reason} ->
        Tools.error("cannot confine the search: #{inspect(reason)}")

      {:error, reason} ->
        Tools.error("cannot run rg: #{inspect(reason)}")
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

  # -- result formatting -------------------------------------------------------

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

  defp clip(line) do
    if String.length(line) <= @max_line_length do
      line
    else
      String.slice(line, 0, @max_line_length) <> "..."
    end
  end

  defp abs_path(scope, path), do: Path.expand(path, Path.expand(scope.root))
end
