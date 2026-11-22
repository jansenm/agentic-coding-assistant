# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.Edit do
  @moduledoc """
  Targeted string-replacement tool (slice 2e; ADR 030).

  ADR 030 makes this a split operation: a confined read (`cat`), the
  replacement computed in the BEAM, then a confined write (`tee`). The
  read/write split is accepted as harmless — the BEAM already holds the
  content for the model, and the sandbox profile is the single boundary
  for what could be read or written at all.

  Fail-closed semantics are unchanged: the callback *declines to act*
  unless the old string occurs exactly once in the file — an ambiguous or
  stale match is an error for the model to resolve by re-reading, never a
  guess. The ambiguity error names the matching lines (the first ten,
  then "possibly more lines") so widening is one step rather than a
  whole-file re-read. The file's type and existence are probed through
  the same confined executor, so the shape check obeys the profile too (a
  hidden path reads as missing; a read-only bind fails at the write).

  Empty `old_string` on a non-existent file creates the file with
  `new_string` as content (the one sanctioned create path); anything
  else requires the file to exist and the match to be unique.
  """

  alias CodingAgent.Core.Tools

  @max_bytes 256 * 1024
  @timeout_secs 30
  # How many matching lines the ambiguity error names before it stops
  # and says "possibly more": enough to see the shape, short enough to
  # stay one error message.
  @listed_matches 10

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "edit",
      description:
        "Replace an exact string in a file. " <>
          "The old_string must occur EXACTLY ONCE — if it is ambiguous, " <>
          "include more surrounding text to make it unique. Re-read the " <>
          "file if unsure. Use old_string \"\" only to create a new file " <>
          "with new_string as its content. Auto-approved by policy unless " <>
          "a permissions file tightens it.",
      parameter_schema: [
        path: [type: :string, required: true, doc: "File to edit"],
        old_string: [type: :string, required: true, doc: "Exact text to replace"],
        new_string: [type: :string, required: true, doc: "Replacement text"]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  # -- Execution --------------------------------------------------------------

  defp execute(scope, args) do
    path = Map.get(args, :path) || Map.get(args, "path")
    old = Map.get(args, :old_string) || Map.get(args, "old_string")
    new = Map.get(args, :new_string) || Map.get(args, "new_string")

    with :ok <- args_ok?(path, old, new),
         :ok <- shape_ok?(scope, path, old) do
      apply_edit(scope, path, old, new)
    end
  end

  defp args_ok?(path, old, new) when is_binary(path) and is_binary(old) and is_binary(new),
    do: :ok

  defp args_ok?(_, _, _), do: Tools.error("path, old_string and new_string must be strings")

  # Only the empty-old create path may skip existence; every real edit
  # requires a present, regular file. The probe is confined (ADR 030).
  defp shape_ok?(scope, path, old) do
    case Tools.FileExec.stat(scope, path, @timeout_secs) do
      :missing ->
        if old == "" do
          :ok
        else
          Tools.error("no such file: #{inspect(path)}")
        end

      :dir ->
        if old == "" do
          Tools.error("file already exists: #{inspect(path)}; it is a directory")
        else
          Tools.error("path is a directory, not a file: #{inspect(path)}")
        end

      :file ->
        if old == "" do
          Tools.error(
            "file already exists: #{inspect(path)}; provide an old_string to replace part of it"
          )
        else
          :ok
        end
    end
  end

  defp apply_edit(scope, path, old, new) do
    # create path: old == "" and the file does not exist (shape_ok?
    # guaranteed both)
    content_result =
      if old == "" do
        {:ok, ""}
      else
        case Tools.FileExec.read(scope, path, @timeout_secs, @max_bytes) do
          {:ok, content} ->
            {:ok, content}

          {:error, message} ->
            {:error, message <> "; use shell for big files"}
        end
      end

    with {:ok, content} <- content_result,
         count <- occurrences(content, old),
         :ok <- uniqueness_ok?(path, content, old, count) do
      updated = String.replace(content, old, new, global: false)

      case Tools.FileExec.write(scope, path, updated, @timeout_secs) do
        {:ok, _path} ->
          {:ok, "edited #{path} (1 replacement, file now #{String.length(updated)} chars)"}

        {:error, message} ->
          Tools.error(message)
      end
    end
  end

  # The fail-closed gate: 0 matches is a stale match; 2+ is ambiguous.
  # Both refuse — the model must re-read and widen, never the tool guess.
  # The ambiguity error names where the matches are, so widening is one
  # step instead of a whole-file re-read; past @listed_matches it stops
  # and says so rather than printing every line of a generated or
  # minified file.
  defp uniqueness_ok?(_path, _content, _old, 1), do: :ok

  defp uniqueness_ok?(path, _content, _old, 0) do
    Tools.error(
      "old_string not found in #{inspect(path)}; re-read the file and match the " <>
        "exact text including whitespace"
    )
  end

  defp uniqueness_ok?(path, content, old, count) do
    listed = content |> match_lines(old) |> Enum.take(@listed_matches)

    more = if count > @listed_matches, do: ", possibly more lines", else: ""

    Tools.error(
      "old_string is ambiguous in #{inspect(path)}: #{count} matches on lines " <>
        "#{Enum.join(listed, ", ")}#{more}; include more surrounding text to make it unique"
    )
  end

  # 1-based line number of each match's start. `:binary.matches/2` is
  # non-overlapping, the same set `occurrences/2` counts; overlapping
  # matches are not matches. Only the first @listed_matches are resolved
  # (each needs the newlines before it), so a single-word old_string in a
  # big file costs a linear scan, not one scan per match.
  defp match_lines(content, old) do
    content
    |> :binary.matches(old)
    |> Stream.map(fn {offset, _len} -> 1 + newlines(binary_part(content, 0, offset)) end)
  end

  defp newlines(prefix), do: prefix |> :binary.matches("\n") |> length()

  # split-1 == count of non-overlapping occurrences
  defp occurrences(content, old), do: content |> String.split(old) |> length() |> Kernel.-(1)
end
