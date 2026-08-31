defmodule CodingAgent.Core.Tools.Grep do
  @moduledoc """
  Read-only content search tool (slice 2d), per the ROADMAP 2d design:
  line-numbered matches, capped results, pure Elixir (no ripgrep
  dependency, ADR 002).

  Containment is enforced by `CodingAgent.Core.Containment` (the ONE
  walk implementation — dir and file scope checks included). Binary
  files are skipped; hidden dirs and `_build`/`deps`/`.git` are
  skipped (never useful to search, always wasteful to walk).
  """

  alias CodingAgent.Core.Containment
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

  defp do_search(scope, pattern, path, glob) do
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
