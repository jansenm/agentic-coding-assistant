defmodule CodingAgent.Core.Tools.Glob do
  @moduledoc """
  Read-only filename search tool (slice 2d): glob patterns over the
  scope, sorted, capped. Pure Elixir walk + pure-string glob matching
  (Elixir 1.20 removed `Path.match/2`), same dialect as the permission
  layer plus `{a,b}` braces. No ripgrep/fd dependency (ADR 002).

  Containment matches the other read-only tools: every returned path
  must survive `Tools.in_scope?/2` (physical symlink resolution), so a
  glob cannot list files outside the scope — symlinks pointing out are
  silently skipped rather than listed.
  """

  alias CodingAgent.Core.Tools

  @max_results 500
  @skip_dirs MapSet.new(["_build", "deps", ".git", "doc", "cover", ".elixir_ls"])

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
      root
      |> walk(root, [])
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

  defp walk(dir, root, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce(acc, fn entry, acc ->
          full = Path.join(dir, entry)

          cond do
            File.dir?(full) ->
              if skip_dir?(entry) or not Tools.in_scope?(%{root: root}, full),
                do: acc,
                else: walk(full, root, acc)

            # files are scope-checked too — a symlinked file pointing out
            # must be skipped, not listed (leak via listing)
            File.regular?(full) and Tools.in_scope?(%{root: root}, full) ->
              [full | acc]

            true ->
              acc
          end
        end)

      {:error, _} ->
        acc
    end
  end

  defp skip_dir?(name) do
    String.starts_with?(name, ".") or MapSet.member?(@skip_dirs, name)
  end

  # -- Pure-string glob matching (Elixir 1.20 has no Path.match/2) -------

  @doc """
  Glob match against a path string: `**` spans segments, `*`/`?` are
  per-segment, `{a,b}` braces expand. Same dialect as the permission
  layer, plus braces.
  """
  def glob_match?(pattern, path) do
    pattern
    |> expand_braces()
    |> Enum.any?(&Regex.match?(glob_regex(&1), path))
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

  # Semantics: a glob is a "/"-joined sequence where any segment may be
  # "**". A "**" segment matches ZERO or more whole directories. So we
  # compile to a regex where "**" becomes the marker (?:[^/]+/)* — zero
  # or more complete segments. Trivially correct: "lib/**/*.ex" then
  # matches both "lib/a.ex" and "lib/x/y/a.ex".

  # Build the regex by consuming a segment list, so that "**" can merge
  # with the following slash instead of being joined by one:
  #   segments ["lib", "**", "*.ex"]  ->  lib/((?:[^/]+/)+)?[^/]*\\.ex
  # i.e. "lib/", then optionally any number of full segments, then the file.
  defp glob_regex(pattern) do
    segments = String.split(pattern, "/", trim: false)
    Regex.compile!("^" <> build(segments) <> "$")
  end

  defp build([]), do: ""

  defp build(["**" | rest]) do
    case rest do
      [] ->
        "(?:.*)?"

      _ ->
        # "**" = zero or more complete "segment/" groups
        "(?:(?:" <> build(rest) <> ")|(?:[^/]+/)+(?:" <> build(rest) <> "))?"
    end
  end

  defp build([seg | rest]) do
    segment_regex(seg) <> if(rest == [], do: "", else: "/" <> build(rest))
  end

  defp segment_regex(seg) do
    seg
    |> Regex.escape()
    |> String.replace("\\*", "[^/]*")
    |> String.replace("\\?", "[^/]")
  end
end
