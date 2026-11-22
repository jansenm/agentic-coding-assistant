# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

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

  @doc "The tool name (the registry key and the model's call name)."
  @spec name() :: String.t()
  def name, do: "move_region"

  @doc """
  The call arguments that name filesystem paths, for the permission gate.
  """
  @spec path_arguments() :: [Tools.path_argument()]
  def path_arguments, do: [from_path: :required, to_path: :required]

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
          "move is allowed (reordering functions); two spellings of one path " <>
          "(`a.ex`, `./a.ex`) count as one file, and a symlink or hardlink to " <>
          "the source is refused rather than written twice; a position inside " <>
          "the region is refused. Set `dry_run: true` to see the line numbers " <>
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

    with {:ok, position} <- position,
         :ok <- paths_ok(from_path, to_path),
         {:ok, same_file?} <- same_file?(scope, from_path, to_path),
         {:ok, source} <- read(scope, from_path),
         {:ok, dest} <- destination(scope, to_path, same_file?),
         {:ok, result} <-
           Region.move(source, dest.text, from, to, position,
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

  # "Same file?" cannot be decided by comparing the two strings: `a.ex` and
  # `./a.ex` are one file, and a symlink is one file under two names. The
  # absolute form settles the spellings (it is the resolution the confined
  # child does, from the scope root); the LINKS are settled after the fact by
  # `verify/4`, because resolving them would be a BEAM filesystem access and
  # the boundary is the sandbox (ADR 030).
  defp same_file?(scope, from_path, to_path) do
    {:ok, FileExec.absolute(scope, from_path) == FileExec.absolute(scope, to_path)}
  end

  defp read(scope, path) do
    case FileExec.stat(scope, path, @timeout_secs) do
      :file -> FileExec.read(scope, path, @timeout_secs, @max_bytes)
      :dir -> Tools.error("#{path} is a directory")
      :missing -> Tools.error("no such file: #{inspect(path)}")
    end
  end

  # The destination's text, and whether it was there at all. A destination
  # that does not exist yet is a new file (the region becomes its whole
  # content); `write` creates it, so that is not a special case further
  # down — but the UNDO is, and it needs the difference.
  defp destination(scope, path, true = _same_file?) do
    with {:ok, text} <- read(scope, path), do: {:ok, %{text: text, existed?: true}}
  end

  defp destination(scope, path, _same_file?) do
    case FileExec.stat(scope, path, @timeout_secs) do
      :file ->
        with {:ok, text} <- FileExec.read(scope, path, @timeout_secs, @max_bytes),
             do: {:ok, %{text: text, existed?: true}}

      :missing ->
        {:ok, %{text: "", existed?: false}}

      :dir ->
        Tools.error("#{path} is a directory")
    end
  end

  defp report_dry(result, from_path, to_path) do
    {:ok,
     "dry run: #{result.region} line(s) from #{from_path}:#{result.from_line} " <>
       "would land in #{to_path}:#{result.to_line} (nothing written)"}
  end

  defp write(scope, result, {from_path, to_path}, _destination, true) do
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

  defp write(scope, result, {from_path, to_path}, destination, false) do
    # Cross-file, destination first: it is the write that GROWS the
    # filesystem (and it happens while space is still free); the source
    # then shrinks by the region, so it cannot fail on space. A crash in
    # between duplicates the region — visible — instead of losing it.
    with {:ok, _} <- FileExec.write(scope, to_path, result.dest, @timeout_secs) do
      case FileExec.write(scope, from_path, result.source, @timeout_secs) do
        {:ok, _} ->
          verify(scope, result, {from_path, to_path}, destination)

        {:error, source_error} ->
          # Put the destination back. `destination.text` is what the file
          # held before this call ("" when it did not exist) — the ONLY copy,
          # since the write replaced it.
          restore(scope, {to_path, destination}, source_error, from_path)
      end
    end
  end

  # The two writes are only correct if the two paths are two files. When they
  # are one file under two names (a symlink, a hardlink, a bind mount — none
  # of which the absolute-path comparison can see), the second write
  # OVERWROTE the first, and what is on disk is the source text at both
  # names: the region is gone. Read both back and say so.
  #
  # The read is the point (review N133, the class is "a success that is not
  # one"): an identity check before the writes is a claim, and the claim and
  # the writes can disagree. This costs two confined reads per move.
  defp verify(scope, result, {from_path, to_path}, destination) do
    source = reread(scope, from_path, result.source)
    dest = reread(scope, to_path, result.dest)

    cond do
      source == {:ok, result.source} and dest == {:ok, result.dest} ->
        {:ok, done(result, from_path, to_path)}

      source == {:ok, result.source} and dest == {:ok, result.source} ->
        collision(scope, result, {from_path, to_path}, destination)

      true ->
        {:error,
         "the move reported success but the files do not hold what it computed: " <>
           "#{from_path} and #{to_path} were both written, and reading them back " <>
           "does not match. Check both files by hand. The region it moved was:\n\n" <>
           result.region_text}
    end
  end

  # A read with the cap sized to what the file SHOULD hold: the destination
  # grows by the region, so the input cap would reject the very result we are
  # checking (and a file bigger than its own expected text is not one we
  # wrote, which the comparison below then sees as a mismatch).
  defp reread(scope, path, expected) do
    cap = max(@max_bytes, byte_size(expected) + 1)
    FileExec.read(scope, path, @timeout_secs, cap)
  end

  # One file under two names: the destination write was overwritten by the
  # source write, so the file holds the source text at both paths. Undo the
  # destination exactly as in `restore/4` and refuse the move.
  defp collision(scope, result, {from_path, to_path}, destination) do
    case undo_dest(scope, to_path, destination) do
      :ok ->
        {:error,
         "refusing: #{from_path} and #{to_path} are the SAME file under two names " <>
           "(a symlink or a hardlink, which a path comparison cannot see), so the " <>
           "move would write both texts into one file and lose the region. " <>
           "Nothing was moved and #{to_path} was put back."}

      {:error, undo_error} ->
        {:error,
         "INCONSISTENT: #{from_path} and #{to_path} are the same file, so the move " <>
           "wrote both texts into it and the region is gone; putting it back failed " <>
           "(#{undo_error}). The region to re-insert is:\n\n#{result.region_text}"}
    end
  end

  # The exact undo of the destination write: remove it when it did not exist
  # before this call, put the original bytes back when it did.
  defp undo_dest(scope, to_path, %{existed?: false}) do
    case FileExec.remove(scope, to_path, [], @timeout_secs) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp undo_dest(scope, to_path, %{text: original}) do
    case FileExec.write(scope, to_path, original, @timeout_secs) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore(scope, {to_path, destination}, source_error, from_path) do
    case undo_dest(scope, to_path, destination) do
      :ok ->
        {:error,
         "moved nothing: writing #{from_path} failed (#{source_error}), " <>
           "and #{if destination.existed?, do: "#{to_path} was restored to its original content", else: "the new #{to_path} was removed again"}"}

      {:error, undo_error} ->
        inconsistent(from_path, to_path, source_error, undo_error)
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
