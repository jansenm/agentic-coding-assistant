defmodule CodingAgent.Core.Tools.MoveRegion do
  @moduledoc """
  Move a line-aligned region of one file into another (ADR 045).

  The computation is `CodingAgent.Core.Region` (pure, unit-tested); this
  module is the confined I/O around it, and the two are split for the usual
  reason: the interesting half — anchors, ambiguity, offsets — needs no
  sandbox, and the sandbox half is the boring one.

  ## Why the write order is destination-first

  A cross-file move makes two writes, and they cannot be atomic. The order
  is chosen so that a crash leaves the region **duplicated** (visible,
  compiles or does not, one keystroke away) rather than **lost**:

    1. compute both texts in the BEAM — nothing written yet;
    2. write the destination (the only write that GROWS the filesystem, and
       it happens while space is still free);
    3. write the source (`-R`: it shrinks, so it cannot fail on space);
    4. if (3) fails, restore the destination from the bytes kept in step 1.

  A same-file move cannot be split across two writes at all, so it writes
  the whole new text to a temporary file BESIDE the target (same
  filesystem — a rename across `/tmp` and the scope root would degrade to
  copy+unlink) and renames over the original. The original's bytes stay
  intact until the rename.

  ## What it does not do

  It does not format (`mix format` is the caller's next step) and it does
  not tidy what the move left behind: `alias`es, `import`s and module
  attributes stay where they were, because deciding which ones a moved
  block still needs is a semantic question, not a textual one. The result
  message says what WAS checked (both files parse, for `.ex`/`.exs`) and
  that `mix compile` is the real check.
  """

  alias CodingAgent.Core.{Region, ToolCall}
  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.FileExec

  @timeout_secs 30
  @max_bytes 256 * 1024

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "move_region",
      description:
        "Move a line-aligned region out of one file into another (or " <>
          "reorder it inside one). `from` and `to` are exact anchor strings: " <>
          "`from` must occur EXACTLY ONCE in the file, `to` is looked for at " <>
          "or after it. The region is extended to whole lines. `position` is " <>
          ":begin, :end, {:before, anchor} or {:after, anchor}, and that " <>
          "anchor must occur exactly once in the destination. A same-file " <>
          "move is allowed (reordering functions); a position inside the " <>
          "region is refused. Set `dry_run: true` to see the line numbers " <>
          "without writing. It does NOT format and does not move aliases, " <>
          "imports or attributes with the region — run `mix format` and " <>
          "`mix compile` afterwards. Auto-approved by policy unless a " <>
          "permissions file tightens it.",
      parameter_schema: [
        from_path: [type: :string, required: true, doc: "File the region comes out of"],
        to_path: [
          type: :string,
          required: true,
          doc: "File the region goes into (the same path for a reorder)"
        ],
        from: [type: :string, required: true, doc: "First line of the region (unique)"],
        to: [type: :string, required: true, doc: "Last line of the region"],
        position: [
          type: :string,
          required: true,
          doc: ":begin | :end | {:before, anchor} | {:after, anchor}"
        ],
        dry_run: [
          type: :boolean,
          required: false,
          doc: "Report the line numbers without writing (default false)"
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  defp execute(scope, args) do
    from_path = arg(args, :from_path)
    to_path = arg(args, :to_path)
    from = arg(args, :from)
    to = arg(args, :to)
    position = parse_position(arg(args, :position))
    dry_run? = arg(args, :dry_run) || false
    same_file? = from_path == to_path

    with {:ok, position} <- position,
         :ok <- paths_ok(from_path, to_path),
         {:ok, source} <- read(scope, from_path),
         {:ok, dest} <- read_or_empty(scope, to_path, same_file?),
         {:ok, result} <-
           Region.move(source, dest, from, to, position,
             same_file?: same_file?,
             source_path: from_path,
             dest_path: to_path
           ) do
      if dry_run? do
        report_dry(result, from_path, to_path)
      else
        write(scope, result, {from_path, to_path}, dest, same_file?)
      end
    end
  end

  defp arg(args, key), do: Map.get(args, key) || Map.get(args, Atom.to_string(key))

  # The tool schema cannot express `:begin | {:before, "x"}` faithfully in
  # JSON, so it arrives as a string and is parsed here: ":begin", ":end",
  # "before: <anchor>", "after: <anchor>". A map form is accepted too, for
  # a caller that passes the term through unchanged.
  @doc false
  def parse_position(":begin"), do: {:ok, :begin}
  def parse_position("begin"), do: {:ok, :begin}
  def parse_position(":end"), do: {:ok, :end}
  def parse_position("end"), do: {:ok, :end}
  def parse_position("before: " <> anchor), do: before(anchor)
  def parse_position("before:" <> anchor), do: before(anchor)
  def parse_position("after: " <> anchor), do: after_(anchor)
  def parse_position("after:" <> anchor), do: after_(anchor)
  def parse_position(%{"before" => anchor}), do: before(anchor)
  def parse_position(%{"after" => anchor}), do: after_(anchor)
  def parse_position({:before, anchor}) when is_binary(anchor), do: {:ok, {:before, anchor}}
  def parse_position({:after, anchor}) when is_binary(anchor), do: {:ok, {:after, anchor}}

  def parse_position(other) do
    Tools.error(
      "position must be \":begin\", \":end\", \"before: <anchor>\" or " <>
        "\"after: <anchor>\", got: #{inspect(other)}"
    )
  end

  defp before(anchor) do
    case String.trim(anchor) do
      "" -> Tools.error("position \"before:\" needs an anchor")
      a -> {:ok, {:before, a}}
    end
  end

  defp after_(anchor) do
    case String.trim(anchor) do
      "" -> Tools.error("position \"after:\" needs an anchor")
      a -> {:ok, {:after, a}}
    end
  end

  defp paths_ok(from_path, to_path) when is_binary(from_path) and is_binary(to_path) do
    cond do
      from_path == "" -> Tools.error("from_path must be a non-empty string")
      to_path == "" -> Tools.error("to_path must be a non-empty string")
      true -> :ok
    end
  end

  defp paths_ok(_, _), do: Tools.error("from_path and to_path must be strings")

  defp read(scope, path) do
    case FileExec.stat(scope, path, @timeout_secs) do
      :file -> FileExec.read(scope, path, @timeout_secs, @max_bytes)
      :dir -> Tools.error("#{path} is a directory")
      :missing -> Tools.error("no such file: #{inspect(path)}")
    end
  end

  # A destination that does not exist yet is a new file (the region becomes
  # its whole content); `write` creates it, so this is not a special case
  # further down.
  defp read_or_empty(scope, path, same_file?) do
    if same_file? do
      read(scope, path)
    else
      case FileExec.stat(scope, path, @timeout_secs) do
        :file -> FileExec.read(scope, path, @timeout_secs, @max_bytes)
        :missing -> {:ok, ""}
        :dir -> Tools.error("#{path} is a directory")
      end
    end
  end

  defp report_dry(result, from_path, to_path) do
    {:ok,
     "dry run: #{result.region} line(s) from #{from_path}:#{result.from_line} " <>
       "would land in #{to_path}:#{result.to_line} (nothing written)"}
  end

  defp write(scope, result, {from_path, to_path}, _original, true) do
    # One file, one write: the new text goes to a temporary file BESIDE the
    # target (same filesystem, so the rename is atomic) and moves over it.
    tmp = from_path <> ".move-tmp"

    with {:ok, _} <- FileExec.write(scope, tmp, result.dest, @timeout_secs),
         {:ok, _} <- FileExec.move(scope, tmp, from_path, [force: true], @timeout_secs) do
      {:ok, done(result, from_path, to_path)}
    else
      {:error, reason} ->
        _ = FileExec.remove(scope, tmp, [], @timeout_secs)
        {:error, "same-file move failed, the file is unchanged: #{reason}"}
    end
  end

  defp write(scope, result, {from_path, to_path}, original_dest, false) do
    # Cross-file, destination first: it is the write that GROWS the
    # filesystem (and it happens while space is still free); the source
    # then shrinks by the region, so it cannot fail on space. A crash in
    # between duplicates the region — visible — instead of losing it.
    with {:ok, _} <- FileExec.write(scope, to_path, result.dest, @timeout_secs) do
      case FileExec.write(scope, from_path, result.source, @timeout_secs) do
        {:ok, _} ->
          {:ok, done(result, from_path, to_path)}

        {:error, source_error} ->
          # Put the destination back. `original_dest` is what the file held
          # before this call ("" when it did not exist), kept from the read
          # in `execute/2` — the ONLY copy, since the write replaced it.
          restore(scope, {to_path, original_dest}, source_error, from_path)
      end
    end
  end

  defp restore(scope, {to_path, original_dest}, source_error, from_path) do
    if original_dest == "" do
      # The destination did not exist before this call: removing it is the
      # exact undo of having created it.
      case FileExec.remove(scope, to_path, [], @timeout_secs) do
        {:ok, _} ->
          {:error,
           "moved nothing: writing #{from_path} failed (#{source_error}), " <>
             "and the new #{to_path} was removed again"}

        {:error, remove_error} ->
          inconsistent(from_path, to_path, source_error, remove_error)
      end
    else
      case FileExec.write(scope, to_path, original_dest, @timeout_secs) do
        {:ok, _} ->
          {:error,
           "moved nothing: writing #{from_path} failed (#{source_error}), " <>
             "and #{to_path} was restored to its original content"}

        {:error, restore_error} ->
          inconsistent(from_path, to_path, source_error, restore_error)
      end
    end
  end

  defp inconsistent(from_path, to_path, source_error, undo_error) do
    {:error,
     "INCONSISTENT: #{to_path} now holds the region and #{from_path} still " <>
       "holds it too (duplicated); undoing the destination failed " <>
       "(#{undo_error}) after the source write failed (#{source_error}). " <>
       "Remove the duplicate by hand."}
  end

  defp done(result, from_path, to_path) do
    "moved #{result.region} line(s) from #{from_path}:#{result.from_line} " <>
      "to #{to_path}:#{result.to_line}. Both files parse if they are .ex/.exs; " <>
      "run `mix format` and `mix compile` — a moved block does not take its " <>
      "aliases, imports or module attributes with it."
  end

  @doc false
  def call(scope, call) do
    {_id, _name, args} = ToolCall.normalize(call)
    execute(scope, args)
  end
end
