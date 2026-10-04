defmodule CodingAgent.Core.Tools.DeleteFile do
  @moduledoc """
  Path deletion tool (ADR 045; ADR 030).

  The delete is a confined `rm` through `Tools.FileExec`, so the sandbox
  profile is the boundary: a path the profile hides or binds read-only
  fails at the removal. The parameters mirror the tool's own flags —
  `dir` is `rm --dir` (an empty directory, or any symlink: `rm` removes
  the LINK, never its target) and `recursive` is `rm --recursive` (a
  directory with its contents). No flag is inferred, and no pre-check
  replaces `rm`'s own message: a directory without the matching flag is
  `rm`'s "Is a directory" / "Directory not empty", an error the model
  reads and corrects in one round.

  Allow-by-policy like the other contained write tools (ADR 010
  amendment, 2026-09-15): a policy file can turn it into ask/deny per
  path (`[permissions.delete_file] "config/**" = "ask"`).
  """

  alias CodingAgent.Core.Tools

  @timeout_secs 30

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "delete_file",
      description:
        "Delete a path. A plain file needs no flag. A directory needs " <>
          "`dir: true` when it is empty, or `recursive: true` to remove it " <>
          "with its contents. A symlink is removed as the LINK, never its " <>
          "target (`rm` semantics). Auto-approved by policy unless a " <>
          "permissions file tightens it.",
      parameter_schema: [
        path: [type: :string, required: true, doc: "Path to delete"],
        dir: [
          type: :boolean,
          required: false,
          doc: "Pass `--dir`: delete an empty directory, or a symlink"
        ],
        recursive: [
          type: :boolean,
          required: false,
          doc: "Pass `--recursive`: delete a directory and its contents"
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  defp execute(scope, args) do
    path = Map.get(args, :path) || Map.get(args, "path")

    if is_binary(path) and path != "" do
      opts = [
        dir: flag(args, :dir),
        recursive: flag(args, :recursive)
      ]

      case Tools.FileExec.remove(scope, path, opts, @timeout_secs) do
        {:ok, _path} -> {:ok, "deleted #{path}"}
        {:error, message} -> Tools.error(message)
      end
    else
      Tools.error("path must be a non-empty string")
    end
  end

  defp flag(args, key), do: Map.get(args, key) || Map.get(args, to_string(key)) || false
end
