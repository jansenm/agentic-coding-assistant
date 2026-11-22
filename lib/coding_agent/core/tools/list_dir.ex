# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.ListDir do
  @moduledoc """
  Read-only directory listing tool (slice 2a; ADR 030).

  The listing is a confined `ls` through `Tools.FileExec`; the profile
  decides what exists to be listed. Names are emitted one per line with
  directories marked by a trailing slash — the shape the previous BEAM
  implementation produced, so the model-visible contract is unchanged.
  """

  alias CodingAgent.Core.Tools

  @timeout_secs 30

  @doc "The tool name (the registry key and the model's call name)."
  @spec name() :: String.t()
  def name, do: "list_dir"

  @doc """
  The call arguments that name filesystem paths, for the permission gate.
  """
  @spec path_arguments() :: [Tools.path_argument()]
  def path_arguments, do: [path: "."]

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "list_dir",
      description:
        "List the entries of a directory. " <>
          "Returns names, one per line, directories marked with a trailing slash.",
      parameter_schema: [
        path: [
          type: :string,
          required: false,
          default: ".",
          doc: "Directory to list (relative paths resolve against the session scope root)"
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  defp execute(scope, args) do
    path = Map.get(args, :path) || Map.get(args, "path") || "."

    # `-p` marks directories with a trailing slash (POSIX); `-1` forces
    # one name per line even when stdout is not a tty. `FileExec.list/4`
    # adds `--` before the path, so a name starting with `-` is safe.
    case Tools.FileExec.list(scope, path, ["-1", "-p"], @timeout_secs) do
      {:ok, output} ->
        {:ok, output |> String.split("\n", trim: true) |> Enum.sort() |> Enum.join("\n")}

      {:error, message} ->
        Tools.error("cannot list #{path}: #{message}")
    end
  end
end
