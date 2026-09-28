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
  guess. The file's type and existence are probed through the same
  confined executor, so the shape check obeys the profile too (a hidden
  path reads as missing; a read-only bind fails at the write).

  Empty `old_string` on a non-existent file creates the file with
  `new_string` as content (the one sanctioned create path); anything
  else requires the file to exist and the match to be unique.
  """

  alias CodingAgent.Core.Tools

  @max_bytes 256 * 1024
  @timeout_secs 30

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
         :ok <- uniqueness_ok?(path, count) do
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
  defp uniqueness_ok?(path, count) do
    cond do
      count == 0 ->
        Tools.error(
          "old_string not found in #{inspect(path)}; re-read the file and match the " <>
            "exact text including whitespace"
        )

      count > 1 ->
        Tools.error(
          "old_string is ambiguous in #{inspect(path)}: #{count} matches; include more " <>
            "surrounding text to make it unique"
        )

      true ->
        :ok
    end
  end

  # split-1 == count of non-overlapping occurrences
  defp occurrences(content, old), do: content |> String.split(old) |> length() |> Kernel.-(1)
end
