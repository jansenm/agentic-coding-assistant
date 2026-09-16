defmodule CodingAgent.Core.Tools.Glob do
  @moduledoc """
  Read-only filename search tool (slice 2d): glob patterns over the
  scope, sorted, capped. Pure Elixir walk + pure-string glob matching
  (Elixir 1.20 removed `Path.match/2`), same dialect as the permission
  layer plus `{a,b}` braces. No ripgrep/fd dependency (ADR 002).

  Containment is enforced by `CodingAgent.Core.Containment` — the one
  walk implementation, with dir and file scope checks — so a glob
  cannot list paths outside the scope: out-of-scope symlinks are
  silently skipped rather than listed.
  """

  alias CodingAgent.Core.Containment
  alias CodingAgent.Core.Tools

  @max_results 500

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
  # with the permission layer, codereview §10). Glob adds brace
  # expansion on top, a search-time convenience the policy loader does
  # not offer.

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
