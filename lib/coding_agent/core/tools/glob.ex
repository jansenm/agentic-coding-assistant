defmodule CodingAgent.Core.Tools.Glob do
  @moduledoc """
  Read-only filename search tool (slice 2d): glob patterns over the
  scope, sorted, capped.

  **Delegates to `fd` when available** (ADR 016), with the pure-Elixir
  walk as the reference fallback (portability, and `fd` may be absent).
  The dialect is the same in both paths: `**` spans segments, `*`/`?` are
  per-segment, `{a,b}` braces expand — `fd --glob` implements exactly
  this, so no translation is needed beyond the braces it already handles.

  Containment is preserved: `fd` is run with `--no-ignore` (our skip
  rules, not the repo's, decide) and explicit excludes for the shared
  build/vendor dirs; every returned path is re-checked physically against
  the scope, so an out-of-scope symlink can never be listed. The
  pure-Elixir path enforces the same via `CodingAgent.Core.Containment`
  (the ONE walk implementation).
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
          "paths sorted. Hidden and build/vendor directories are skipped. " <>
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
    root = Path.expand(scope.root)

    args =
      ["--glob", "--color=never", "--no-ignore", "--type", "f"] ++
        exclude_args() ++
        [pattern, "."]

    # Same confined-process path as grep: run fd through Exec under the
    # read-only sandbox profile instead of a bare System.cmd.
    profile = scope |> Tools.profile() |> Map.put(:root, root)

    case Exec.run({:exec, fd, args}, root, @exec_timeout, profile) do
      {:ok, out, 0} -> format_fd_matches(out, root)
      {:ok, out, 1} -> format_fd_matches(out, root)
      _ -> :fallback
    end
  end

  # fd's --exclude matches by name at any depth, so a bare name prunes
  # nested build/vendor trees just like the Elixir walk.
  defp exclude_args do
    Enum.flat_map(External.skip_dirs(), fn dir -> ["--exclude", dir] end)
  end

  defp format_fd_matches(out, root) do
    matches =
      out
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim_leading(&1, "./"))
      |> Enum.map(&Path.expand(&1, root))
      |> Enum.filter(&Tools.in_scope?(%{root: root}, &1))
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()
      |> Enum.take(@max_results)

    body = Enum.join(matches, "\n")

    suffix =
      if length(matches) == @max_results,
        do: "\n[... capped at #{@max_results} results; narrow the pattern ...]",
        else: ""

    {:ok, if(body == "", do: "(no matches)", else: body <> suffix)}
  end

  # -- pure-Elixir reference implementation ------------------------------------

  defp elixir_match(scope, pattern) do
    root = Path.expand(scope.root)

    matches =
      Containment.walk(scope, ".")
      |> Enum.filter(fn file ->
        rel = Path.relative_to(file, root)
        glob_match?(pattern, rel) or glob_match?(pattern, Path.basename(file))
      end)
      |> Enum.sort()
      |> Enum.take(@max_results)

    body = Enum.map_join(matches, "\n", fn f -> Path.relative_to(f, root) end)

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
