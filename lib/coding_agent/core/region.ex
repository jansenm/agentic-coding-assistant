defmodule CodingAgent.Core.Region do
  @moduledoc """
  A line-aligned region move, computed as pure text (no filesystem).

  This is the operation `Tools.MoveRegion` performs, isolated so the
  interesting half — locating the region, refusing an ambiguous anchor,
  and doing the offset arithmetic — is testable without a sandbox, a
  profile or a session.

  ## Why anchors and not line numbers

  The caller that wants a move has just READ the code, so it has the
  anchor text; only a caller with a stale file has line numbers. That is
  the same contract `Tools.Edit` states for `old_string`, and the same
  failure is possible here: an anchor that matches twice must be an error
  that names the lines, never a guess (measured at ~1 ms for both scans
  of a 208 KB file, so nothing is saved by accepting numbers instead).

  ## The region is line-aligned

  `from` and `to` name the first and last line of the region; the region
  is extended outwards to whole lines and includes the last line's
  newline. Insertion points are line boundaries for the same reason: a
  move is a statement about whole lines, and gluing `end` to whatever
  followed it is never what the caller meant.

  ## Positions

    * `:begin` — before the first line;
    * `{:before, anchor}` — the start of the anchor's line;
    * `{:after, anchor}` — the end of the anchor's line;
    * `:end` — after the last line (a trailing newline is added if the
      file has none).

  ## Same-file moves

  A move inside one file is supported (reordering functions is the common
  case). Positions are resolved in the ORIGINAL text and the region is
  then excised and re-inserted; an insertion point inside the region is
  refused, closed interval `[start, end]`. That single test also covers
  every no-op: `:begin` on a region at offset 0, `{:before, <the start
  anchor>}`, `{:after, <the end anchor>}`, `:end` on a region that ends
  the file. A "move" that would leave the text unchanged is an error, not
  a success.

  ## The parse guard

  When `:source_path` / `:dest_path` name `.ex`/`.exs` files, both results
  must parse, or the move is refused. That is the check whose absence let
  a half-deleted block reach the compiler, where the error surfaced
  several hundred lines away from the damage. It is a syntax check only: a
  moved function whose `alias` stayed behind still parses, and the compile
  is still the real check.
  """

  @typedoc "Where the region goes, in the destination text."
  @type position :: :begin | {:before, String.t()} | {:after, String.t()} | :end

  @typedoc """
  The two texts after the move, plus what the caller needs to report it:
  the region's line count, the line the region occupied and the line it
  lands on (both 1-based, in their own file).
  """
  @type result :: %{
          source: String.t(),
          dest: String.t(),
          region: pos_integer(),
          from_line: pos_integer(),
          to_line: pos_integer()
        }

  @doc """
  Moves the region between `from` and `to` out of `source` and into `dest`
  at `position`.

  `opts`:

    * `:same_file?` — the two texts are the same file (required for the
      offset arithmetic to be meaningful; the caller knows this, the text
      comparison would not);
    * `:source_path` / `:dest_path` — used for the parse guard only.

  Every refusal is a `{:error, message}` naming what to do next.
  """
  @spec move(String.t(), String.t(), String.t(), String.t(), position(), keyword()) ::
          {:ok, result()} | {:error, String.t()}
  def move(source, dest, from, to, position, opts \\ []) do
    with :ok <- anchor_ok(from, "from"),
         :ok <- anchor_ok(to, "to"),
         {:ok, s} <- unique(source, from, "from"),
         {:ok, e} <- end_after(source, to, s),
         {:ok, s, e} <- whole_lines(source, s, e),
         {:ok, o} <- destination(dest, position),
         :ok <- disjoint?(opts, s, e, o, position),
         {:ok, new} <- assemble(source, dest, s, e, o, opts) do
      {:ok, new}
    end
  end

  # -- locating the region ----------------------------------------------------

  defp anchor_ok(text, _name) when is_binary(text) and text != "", do: :ok
  defp anchor_ok(_, name), do: {:error, "`#{name}` must be a non-empty string"}

  # The start anchor must occur exactly once: that is the one place in the
  # file the caller meant, and a second occurrence makes the region
  # ambiguous.
  defp unique(text, anchor, name) do
    case :binary.matches(text, anchor) do
      [{pos, _len}] ->
        {:ok, pos}

      [] ->
        {:error, "`#{name}` anchor not found: #{inspect(anchor)}"}

      matches ->
        {:error, "#{length(matches)} matches for the `#{name}` anchor " <> lines(matches, text)}
    end
  end

  # The end anchor is looked for AT OR AFTER the start: `end` alone is a
  # word that occurs hundreds of times in an Elixir file, so requiring
  # uniqueness in the whole file would make the tool useless there. What
  # must be unique is the region's end.
  defp end_after(text, anchor, from_offset) do
    candidates =
      text
      |> :binary.matches(anchor)
      |> Enum.filter(fn {pos, _len} -> pos >= from_offset end)

    case candidates do
      [{pos, len} | _] -> {:ok, pos + len}
      [] -> {:error, "`to` anchor not found after the `from` anchor: #{inspect(anchor)}"}
    end
  end

  # Outwards to whole lines: the region starts at the beginning of the
  # line the start anchor is on, and ends after the newline of the line
  # the end anchor ends on.
  defp whole_lines(text, s, e) do
    start = line_start(text, s)
    stop = line_stop(text, e)
    {:ok, start, stop}
  end

  defp line_start(text, pos) do
    case text |> binary_part(0, pos) |> :binary.matches("\n") |> List.last() do
      nil -> 0
      {idx, _} -> idx + 1
    end
  end

  # The end of the line the anchor ENDS on. When the anchor already ends on
  # a line boundary (it includes its own newline, which is the common case —
  # `"end\n"`), that position IS the line's end; searching forwards from
  # here would swallow the next line. This was the bug behind three wrong
  # moves: a region that grew by one line, silently.
  defp line_stop(text, pos) when pos > 0 do
    if pos <= byte_size(text) and binary_part(text, pos - 1, 1) == "\n" do
      pos
    else
      next_newline(text, pos)
    end
  end

  defp line_stop(text, pos), do: next_newline(text, pos)

  defp next_newline(text, pos) do
    case :binary.match(text, "\n", scope: {pos, byte_size(text) - pos}) do
      :nomatch -> byte_size(text)
      {idx, _} -> idx + 1
    end
  end

  # -- locating the destination ----------------------------------------------

  defp destination(_dest, :begin), do: {:ok, 0}

  defp destination(dest, :end) do
    # append after the last line; a file without a trailing newline gets
    # one, so the moved lines start on their own line
    {:ok, byte_size(dest)}
  end

  defp destination(dest, {:before, anchor}) do
    with {:ok, pos} <- unique(dest, anchor, "position") do
      {:ok, line_start(dest, pos)}
    end
  end

  defp destination(dest, {:after, anchor}) do
    with {:ok, pos} <- unique(dest, anchor, "position") do
      {:ok, line_stop(dest, pos)}
    end
  end

  defp destination(_dest, other),
    do:
      {:error,
       "unknown position: #{inspect(other)} (use :begin, :end, {:before, a} or {:after, a})"}

  # -- same-file refusal ------------------------------------------------------

  # Closed interval on purpose: `o == e` is `{:after, <the end anchor>}` —
  # "put it right after itself" — and `o == s` is the same no-op from the
  # other side. Both are errors, not silent successes.
  defp disjoint?(opts, s, e, o, position) do
    if Keyword.get(opts, :same_file?, false) and s <= o and o <= e do
      {:error,
       "the position lands inside the region being moved " <>
         "(that move would not change the file); choose a position outside " <>
         "#{inspect(position)}"}
    else
      :ok
    end
  end

  # -- assembly ---------------------------------------------------------------

  defp assemble(source, dest, s, e, o, opts) do
    region = binary_part(source, s, e - s)

    if Keyword.get(opts, :same_file?, false) do
      # One file: excise, then insert at the offset adjusted for the
      # removal. `o > e` and `o < s` are the only two cases left (the
      # interval is refused above), so this has no further special case.
      insert_at = if o < s, do: o, else: o - byte_size(region)
      new = binary_part(source, 0, s) <> binary_part(source, e, byte_size(source) - e)

      new =
        binary_part(new, 0, insert_at) <>
          region <> binary_part(new, insert_at, byte_size(new) - insert_at)

      check(new, new, opts, %{
        region: lines_in(region),
        from_line: line_of(source, s),
        to_line: line_of(new, insert_at)
      })
    else
      new_source = binary_part(source, 0, s) <> binary_part(source, e, byte_size(source) - e)
      new_dest = insert(dest, o, region)

      check(new_source, new_dest, opts, %{
        region: lines_in(region),
        from_line: line_of(source, s),
        to_line: line_of(new_dest, o)
      })
    end
  end

  # A destination with no trailing newline gets one before the region, so
  # the moved lines are not glued to the last line that was there.
  defp insert(dest, o, region) do
    before = binary_part(dest, 0, o)

    before =
      if before == "" or String.ends_with?(before, "\n"), do: before, else: before <> "\n"

    before <> region <> binary_part(dest, o, byte_size(dest) - o)
  end

  defp check(new_source, new_dest, opts, facts) do
    paths = [Keyword.get(opts, :source_path), Keyword.get(opts, :dest_path)]

    case Enum.find(Enum.uniq(paths), &elixir?/1) do
      nil ->
        {:ok, Map.merge(%{source: new_source, dest: new_dest}, facts)}

      path ->
        texts = [new_source, new_dest] |> Enum.uniq()

        case Enum.find(texts, &(Code.string_to_quoted(&1) |> elem(0) == :error)) do
          nil ->
            {:ok, Map.merge(%{source: new_source, dest: new_dest}, facts)}

          bad ->
            {:error,
             "refusing: the result does not parse (#{path}); " <>
               "the region is probably not a complete unit — #{parse_error(bad)}"}
        end
    end
  end

  # `Code.string_to_quoted/1`'s error shape is a meta keyword list, the
  # message (which may be a `{prefix, suffix}` tuple) and a token — all
  # `inspect`ed, because interpolating that meta list raises.
  defp parse_error(text) do
    case Code.string_to_quoted(text) do
      {:error, {meta, message, _token}} -> "at #{inspect(meta)}: #{inspect(message)}"
      {:error, other} -> inspect(other)
      _ -> "unknown syntax error"
    end
  end

  defp elixir?(path) when is_binary(path), do: Path.extname(path) in [".ex", ".exs"]
  defp elixir?(_), do: false

  # -- small readers ----------------------------------------------------------

  defp lines_in(region), do: region |> :binary.matches("\n") |> length() |> max(1)

  defp line_of(text, pos) do
    text
    |> binary_part(0, min(pos, byte_size(text)))
    |> :binary.matches("\n")
    |> length()
    |> Kernel.+(1)
  end

  defp lines(matches, text) do
    listed =
      matches |> Enum.take(10) |> Enum.map_join(", ", fn {pos, _} -> "#{line_of(text, pos)}" end)

    more = if length(matches) > 10, do: ", possibly more lines", else: ""
    "on lines #{listed}#{more}"
  end
end
