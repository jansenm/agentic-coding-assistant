defmodule CodingAgent.Core.Tools.Edit do
  @moduledoc """
  Targeted string-replacement tool (slice 2e). Allow-by-policy (ADR 010
  amendment, 2026-09-15): the fence is structural, not social —
  contained paths (physically resolved), fail-closed matching below,
  and every landed change reviewable as a VCS diff. `write_file`
  (whole-file overwrite, no uniqueness gate) and `shell` (no
  containment) remain behind the approval prompt. A repo or user
  policy file can still turn edit into ask/deny per path
  (`[permissions.edit] "src/**" = "ask"`).

  Why string replacement instead of whole-file writes: models reproduce
  entire files expensively and error-prone; `edit` ships only the
  changed span. Fail-closed semantics are the safety feature: the
  callback *declines to act* unless the old string occurs exactly once
  in the file — an ambiguous or stale match is an error for the model
  to resolve by re-reading, never a guess.

  Empty `old_string` on a non-existent file creates the file with
  `new_string` as content (the one sanctioned create path); anything
  else requires the file to exist and the match to be unique.
  """

  alias CodingAgent.Core.Containment
  alias CodingAgent.Core.Tools

  @max_bytes 256 * 1024

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "edit",
      description:
        "Replace an exact string in a file inside the session scope. " <>
          "The old_string must occur EXACTLY ONCE — if it is ambiguous, " <>
          "include more surrounding text to make it unique. Re-read the " <>
          "file if unsure. Use old_string \"\" only to create a new file " <>
          "with new_string as its content. Auto-approved by policy for " <>
          "in-scope paths unless a permissions file tightens it.",
      parameter_schema: [
        path: [type: :string, required: true, doc: "File to edit, within the session scope"],
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
         :ok <- Containment.check_scope!(scope, path),
         :ok <- shape_ok?(scope, path, old) do
      apply_edit(scope, path, old, new)
    end
  end

  defp args_ok?(path, old, new) when is_binary(path) and is_binary(old) and is_binary(new),
    do: :ok

  defp args_ok?(_, _, _), do: Tools.error("path, old_string and new_string must be strings")

  # Only the empty-old create path may skip existence; every real edit
  # requires a present, readable file.
  defp shape_ok?(scope, path, old) do
    file = Path.expand(path, Path.expand(scope.root))

    cond do
      old == "" and File.exists?(file) ->
        Tools.error(
          "file already exists: #{inspect(path)}; provide an old_string to replace part of it"
        )

      old != "" and not File.regular?(file) ->
        Tools.error("no such file: #{inspect(path)}")

      true ->
        :ok
    end
  end

  defp apply_edit(scope, path, old, new) do
    file = Path.expand(path, Path.expand(scope.root))

    # create path: old == "" and the file does not exist (shape_ok?
    # guaranteed both)
    content_result =
      if old == "" do
        {:ok, ""}
      else
        case File.read(file) do
          {:ok, bytes} when byte_size(bytes) > @max_bytes ->
            {:error, "file larger than 256 KiB: #{inspect(path)}; use shell for big files"}

          {:ok, content} ->
            {:ok, content}

          {:error, reason} ->
            {:error, "cannot read #{inspect(path)}: #{:file.format_error(reason)}"}
        end
      end

    with {:ok, content} <- content_result,
         count <- occurrences(content, old),
         :ok <- uniqueness_ok?(path, count) do
      updated = String.replace(content, old, new, global: false)

      case File.write(file, updated) do
        :ok ->
          {:ok, "edited #{path} (1 replacement, file now #{String.length(updated)} chars)"}

        {:error, reason} ->
          Tools.error("cannot write #{inspect(path)}: #{:file.format_error(reason)}")
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

  # occurrences used via function capture to keep it public for tests?
  # No — call it inline; keep private.
end
