# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.DeleteFile do
  @moduledoc """
  Path deletion tool (ADR 045; ADR 030).

  The delete is a confined `rm` through `Tools.FileExec`, so the sandbox
  profile is the boundary: a path the profile hides or binds read-only
  fails at the removal. The parameters mirror the tool's own flags —
  `dir` is `rm --dir` (remove an EMPTY directory) and `recursive` is
  `rm --recursive` (a directory with its contents). A file or a symlink
  needs no flag: `rm` removes the link, never its target. No flag is
  inferred, and where `rm` reports the mismatch itself its message is
  left alone: a directory without the matching flag is `rm`'s "Is a
  directory", an error the model reads and corrects in one round.

  ## A flag that names the wrong shape is refused

  `rm --dir` is happy to remove a plain FILE (measured, GNU coreutils
  9.12: exit 0, no message) — a call that says `dir: true` about a file
  used to report `deleted <path>`, quietly answering a question that was
  not asked (review P28). So the shape is probed first and only a real
  DIRECTORY is accepted under `dir: true`: a file, a symlink, a dangling
  symlink are each refused with a message naming both ways out. A symlink
  to a directory is not a directory for this flag either — it is removed
  as the link it is, and it needs no flag.

  `recursive: true` is always allowed, alone or beside `dir: true`: it
  is the one flag whose meaning does not depend on the shape (an empty
  directory, a full one, a file — and `rm --dir --recursive` descends),
  so no combination of it can be wrong.

  The probe is a confined `ls -dF` (`FileExec.stat/3`): `-F` appends ONE
  marker character, `/` for a directory and `@` for a symlink whatever
  it points at, so the marker decides and the name never does (a name
  may itself end in `@` or `/`).

  A `:missing` path is left to `rm`, whose "No such file or directory"
  is the honest message. The probe answers for the moment it ran; the
  refusal is therefore never stated as the reason `rm` did not run.

  Allow-by-policy like the other contained write tools (ADR 010
  amendment, 2026-09-15): a policy file can turn it into ask/deny per
  path (`[permissions.delete_file] "config/**" = "ask"`).
  """

  alias CodingAgent.Core.Tools

  @timeout_secs 30

  @doc "The tool name (the registry key and the model's call name)."
  @spec name() :: String.t()
  def name, do: "delete_file"

  @doc """
  The call arguments that name filesystem paths, for the permission gate.
  """
  @spec path_arguments() :: [Tools.path_argument()]
  def path_arguments, do: [path: :required]

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "delete_file",
      description:
        "Delete a path. A file or a symlink needs no flag (a symlink is " <>
          "removed as the LINK, never its target — `rm` semantics). A " <>
          "directory needs `dir: true` when it is empty, or `recursive: true` " <>
          "to remove it with its contents; `dir: true` is refused for a path " <>
          "that is not a real directory. Auto-approved by policy unless a " <>
          "permissions file tightens it.",
      parameter_schema: [
        path: [type: :string, required: true, doc: "Path to delete"],
        dir: [
          type: :boolean,
          required: false,
          doc: "Pass `--dir`: delete an empty directory (refused for a file or a symlink)"
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
      dir = flag(args, :dir)
      recursive = flag(args, :recursive)

      with :ok <- shape_agrees(scope, path, dir, recursive) do
        case Tools.FileExec.remove(scope, path, [dir: dir, recursive: recursive], @timeout_secs) do
          {:ok, _path} -> {:ok, "deleted #{path}"}
          {:error, message} -> Tools.error(message)
        end
      end
    else
      Tools.error("path must be a non-empty string")
    end
  end

  # `rm --dir` removes a plain file, and a symlink to a directory is
  # still a symlink (it is removed as the link), so the flag's meaning
  # ("an empty directory") is checked here rather than left to a success
  # with no message. `recursive: true` needs no check: it means the same
  # for every shape. A `:missing` path goes to `rm` for its own message.
  defp shape_agrees(scope, path, dir, recursive)

  defp shape_agrees(_scope, _path, false, _recursive), do: :ok
  defp shape_agrees(_scope, _path, _dir, true), do: :ok

  defp shape_agrees(scope, path, true, false) do
    case Tools.FileExec.stat(scope, path, @timeout_secs) do
      :dir ->
        :ok

      # Nothing is there to check, and `rm`'s own "No such file or
      # directory" is the honest answer to that.
      :missing ->
        :ok

      _file_or_link ->
        Tools.error(
          "#{path} is not a directory; `dir: true` is `rm --dir` (an empty directory) — " <>
            "pass no flag to delete a file or a symlink, or `recursive: true` for a tree"
        )
    end
  end

  defp flag(args, key), do: Map.get(args, key) || Map.get(args, to_string(key)) || false
end
