# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

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

  ## The size cap

  `rg` is passed `--max-filesize 1M`: a directory walk skips any file
  larger than 1 MiB, so a big generated file or log is not searched by
  default (review N3). `rg` applies this cap only during traversal, not to
  an explicitly named target — so `path: "big.txt"` on a single file
  searches it regardless of size; only the directory-walk case skips it.
  The tool description states this so the model can name the file when it
  expects large content.

  The skipped files are LISTED in the result (`skipped: N file(s) over
  1 MiB — name one with \`path\``). A silent skip is an empty answer that
  looks like "no match": found live, the only hit of a repo-wide search
  sat in a 1.4 MB file, and the tool reported nothing at all. When the
  listing ITSELF fails (fd missing, a timeout, an exec error), the note
  names the failure — rendered as "nothing skipped" it would again be an
  answer that reads as a complete search.
  """

  alias CodingAgent.Core.Containment
  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.External
  alias CodingAgent.Core.Spill
  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.Glob

  @max_results 200
  @max_line_length 500
  # The directory-walk size cap (`rg --max-filesize`). Files above it are
  # skipped by the walk and NAMED in the result (see `oversized_files/2`):
  # a skipped file must never be an invisible empty answer.
  @max_file_bytes 1024 * 1024

  # rg runs through the one executor (Exec + Sandbox), so the process is
  # confined like shell/git are.
  @exec_timeout 60

  @doc "The tool name (the registry key and the model's call name)."
  @spec name() :: String.t()
  def name, do: "grep"

  @doc """
  The call arguments that name filesystem paths, for the permission gate.
  """
  @spec path_arguments() :: [Tools.path_argument()]
  def path_arguments, do: [path: "."]

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "grep",
      description:
        "Search file contents inside the session scope with a regular " <>
          "expression. Returns at most #{@max_results} matches " <>
          "as \"path:line: line text\". Skip binary files; ignores standard " <>
          "build/vendor directories. Use glob first to narrow files if needed. " <>
          "A directory search skips files larger than 1 MiB and NAMES them in " <>
          "the result (\"skipped: ...\"), so a bare \"no matches\" never hides an " <>
          "unsearched file; if the size listing itself fails, the answer says so " <>
          "(\"could not check...\"). Name one with `path` to search it in full.",
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
    #
    # `--null` (a NUL after each path) is what makes the plain output
    # UNAMBIGUOUS: a path may contain `:`, so `path:line:text` cannot be
    # split reliably, but `path\0line:text` can, because NUL cannot occur
    # in a path. This replaced `--json` (review F1 follow-up): the JSON
    # stream is the SAME match set but ~6x larger for a normal search and
    # ~25x for a broad one (measured: pattern `.` over 500 files -> 16 MB
    # of JSON vs 686 KB plain), and it had to be `Jason.decode`d line by
    # line. Reading it whole (required so the count/spill are true, F1)
    # made a repo-wide broad search into a hundreds-of-MB decode bomb.
    # The plain+`--null` form carries the identical information at a
    # fraction of the size, with a cheap split instead of per-line JSON.
    #
    # `--with-filename` is REQUIRED (review N2): rg omits the path when
    # the target is a SINGLE named file, so `path\0line:text` degrades to
    # `line:text` and the parser (which needs the NUL) drops every match —
    # a silent empty answer for `grep path: "single.txt"`. `-H` forces
    # the path in every case, keeping the parse uniform.
    args =
      [
        "--null",
        "--with-filename",
        "--line-number",
        "--no-heading",
        "--no-config",
        "--no-ignore",
        "--color=never"
      ] ++
        ["--max-filesize", "1M", "--hidden"] ++
        exclude_args(target) ++
        ["-e", pattern, "--", target]

    # The command runs through Exec under the sandbox profile, exactly
    # like shell/git. Tools.profile/1 builds the profile; a confining
    # sandbox bounds the process (no writes, no network), and the scope
    # is already mountable, so delegation needs nothing else.
    #
    # `truncate: false` is REQUIRED here (review F1): rg's output is
    # machine input, and Exec's default 256 KiB cut would let grep see
    # only a fraction of the matches — the count and the "full list" spill
    # were both drawn from that fragment, so the tool reported "1133 of
    # 1133" for a search with 120 000 hits and spilled the same truncated
    # set. Reading the stream whole makes the count and the spill true; the
    # 60s timeout bounds a pathological search, and the spill itself is
    # capped (ADR 038). It also drops Exec's own spill of the raw excerpt,
    # which had no reader.
    profile = scope |> Tools.profile() |> Map.put(:root, root)

    case Exec.run({:exec, rg, args}, root, @exec_timeout, profile, truncate: false) do
      # The target does not exist (or is out of the profile's reach):
      # rg's own diagnostic is the model-readable answer.
      {:ok, out, 2} when out != "" ->
        {:error, String.trim(out)}

      # exit 1 is "no match" for rg (unlike fd, where 1 is an error —
      # measured)
      {:ok, out, code} when code in [0, 1] ->
        format_rg_matches(out, root, glob, path, scope)

      {:ok, out, _code} ->
        Tools.error("rg failed: #{String.trim(out)}")

      {:timeout, _partial} ->
        Tools.error("rg search timed out after #{@exec_timeout}s")

      {:stopped, _partial} ->
        Tools.error("rg search stopped by the user")

      {:raw_too_large, _partial} ->
        Tools.error(
          "rg produced more output than can be held in memory; narrow the pattern or path"
        )

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
  defp format_rg_matches(out, root, glob, path, scope) do
    names = [glob, path]

    records =
      out
      |> split_rg_records()
      |> Enum.flat_map(&rg_match_record(&1, root))

    # The physical scope re-check (`Tools.in_scope?/2`) is a full
    # realpath walk following symlinks; doing it PER MATCH made a broad
    # search quadratic in hits (measured: 20k matches over 500 files cost
    # 4.4s). Every match on a file shares that file's verdict, so resolve
    # it ONCE per distinct path. The check itself stays: an explicitly
    # named symlink (`path: "src/leak.txt"`) can point outside the scope
    # and rg will happily read through it (verified), so the physical
    # re-check is what keeps an out-of-scope match out of the result.
    allowed =
      records
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.filter(&Tools.in_scope?(%{root: root}, &1))
      |> MapSet.new()

    results =
      records
      |> Enum.filter(fn {abs, _n, _text} -> MapSet.member?(allowed, abs) end)
      |> Enum.map(fn {abs, n, text} -> {Path.relative_to(abs, root), n, text} end)
      |> Enum.filter(&keep_match?(&1, names))
      |> Enum.sort()

    case format_results(results, scope) do
      {:ok, body} ->
        {:ok, body <> skipped_note(root, path, glob)}
    end
  end

  # One match survives when the caller's glob accepts its path (the same
  # `Glob.file_match?/3` the `glob` tool uses) and the hidden rule allows
  # it. Both engines therefore return the same set.
  defp keep_match?({rel, _line, _text}, names) do
    Containment.hidden_allowed?(rel, names) and glob_accepts?(List.first(names), rel)
  end

  defp glob_accepts?(nil, _rel), do: true
  defp glob_accepts?(glob, rel), do: Glob.file_match?(glob, rel, Path.basename(rel))

  # Name the files the walk SKIPPED because they exceed @max_file_bytes.
  #
  # rg's `--max-filesize` is silent by design, and a silent skip turns
  # into an empty answer that reads as "no match" — found live: the only
  # hit of a repo-wide search sat in a 1.4 MB file, and the tool said
  # nothing at all. The model can name one with `path` to search it
  # (rg's cap applies only to the walk, not to a named target, so the
  # re-run searches it in full). The walk stays bounded; only the
  # report grows. A FAILED check is a sentence with the reason, not a
  # silent "nothing skipped" (N123).
  defp skipped_note(root, path, glob) do
    case oversized_files(root, path, glob) do
      {:ok, []} ->
        ""

      {:ok, files} ->
        "\n[skipped: #{length(files)} file(s) over 1 MiB — name one with `path`: #{Enum.join(files, ", ")}]"

      {:error, reason} ->
        "\n[could not check for files over 1 MiB: #{reason}]"
    end
  end

  # The files the walk would skip, or the reason the check could not run
  # (a check that answers `[]` on failure reads as a complete search —
  # N123). An explicitly NAMED file target is not a walk, so rg searches
  # it whatever its size — there is nothing the check could hide, the
  # probe does not even run, and no note appears even when fd is broken.
  # rg's own `--no-ignore`/`--hidden` are reflected in `--hidden` here;
  # the skip-dirs keep the excluded trees out of the count.
  defp oversized_files(root, path, glob) do
    abs = abs_path(%{root: root}, path)

    if File.regular?(abs) do
      {:ok, []}
    else
      case External.probe(:fd) do
        {:ok, fd} -> fd_oversized(fd, root, abs, glob, path)
        :error -> {:error, "fd is not available"}
      end
    end
  end

  defp fd_oversized(fd, root, abs, glob, path) do
    # fd prunes by name, not by rg's `!**/dir/**` glob: the same
    # `External.skip_dirs()` list, expressed the way fd understands it
    # (rg's form made fd treat each pattern as a path — `[fd error]:
    # Search path '!**/_build/**' is not a directory`).
    args =
      ["--type", "f", "--size", "+#{@max_file_bytes}b", "--hidden"] ++
        Enum.flat_map(External.skip_dirs(), fn dir -> ["--exclude", dir] end) ++ ["."]

    profile = Tools.profile(%{root: root}) |> Map.put(:root, root)

    # Every shape of Exec's outcome that is not a clean listing is a
    # `{:error, reason}`: the caller renders the reason, because a
    # fallback to "nothing skipped" repeats N3's invisible-empty-answer
    # class one level up.
    case Exec.run({:exec, fd, args}, abs, 30, profile, truncate: false) do
      {:ok, out, 0} ->
        {:ok,
         out
         |> String.split("\n", trim: true)
         |> Enum.map(&String.trim_leading(&1, "./"))
         |> Enum.filter(&keep_match?({&1, 0, ""}, [glob, path]))
         |> Enum.sort()
         |> Enum.take(10)}

      # exit 1 is an ERROR for fd (unlike rg — measured), as is every
      # other non-zero status
      {:ok, _out, exit_code} ->
        {:error, "fd exited with status #{exit_code}"}

      {:timeout, _partial} ->
        {:error, "the size check timed out after 30s"}

      {:stopped, _partial} ->
        {:error, "the size check was stopped"}

      {:raw_too_large, _partial} ->
        {:error, "the size check produced unholdable output"}

      {:sandbox_error, reason} ->
        {:error, "cannot confine the size check: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "could not run fd: #{inspect(reason)}"}
    end
  end

  # rg's `--null` output is one record per match, `path\0lineno:text`,
  # records separated by `\n` (the matched text is a single line, so a
  # newline only ends a record). Splitting on the newline first is safe
  # precisely because a match's text cannot contain one.
  defp split_rg_records(out), do: String.split(out, "\n", trim: true)

  # `path\0lineno:text` -> `{abs, line, text}` (the scope verdict is added
  # later, once per file). The NUL separates the path from the rest, so a
  # `:` in the PATH cannot be confused with the one before the line
  # number; the first `:` in the REST separates line from text (a `:` in
  # the TEXT is fine). A record without a NUL, or with a non-integer line,
  # is dropped (never a phantom match).
  defp rg_match_record(record, root) do
    with [path, rest] <- String.split(record, "\0", parts: 2),
         [n_str, text] <- String.split(rest, ":", parts: 2),
         {n, ""} <- Integer.parse(n_str) do
      [{Path.expand(path, root), n, clip(String.trim_trailing(text, "\n"))}]
    else
      _ -> []
    end
  end

  defp rel_target(root, path) do
    abs = abs_path(%{root: root}, path)
    Path.relative_to(abs, root)
  end

  # -- result formatting -------------------------------------------------------

  defp format_results(results, scope) do
    total = length(results)

    # The cap keeps the CONTEXT bounded; the full list goes to the session
    # scratch so the model can read the rest (ADR 038) instead of
    # re-running a narrower search.
    truncated =
      if total > @max_results do
        note =
          case spill_matches(results, scope) do
            {:ok, path} -> "; full list at #{path}"
            _ -> ""
          end

        "\n[... capped at #{@max_results} of #{total} matches#{note}; " <>
          "narrow the pattern or path ...]\n"
      else
        ""
      end

    body =
      results
      |> Enum.take(@max_results)
      |> Enum.map(fn {file, line, text} -> "#{file}:#{line}:#{text}" end)
      |> Enum.join("\n")

    {:ok, body <> truncated}
  end

  # The full MATCH LIST (every hit, not just the first @max_results) for
  # the spill file, so the model retrieves the matches the capped view
  # dropped. Per-line text stays clipped to @max_line_length (as in the
  # capped view) — the spill recovers dropped matches, not a megabytes-
  # long single line.
  defp spill_matches(results, scope) do
    body =
      results
      |> Enum.map(fn {file, line, text} -> "#{file}:#{line}:#{text}" end)
      |> Enum.join("\n")

    Spill.spill(body, Tools.profile(scope), "grep")
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
