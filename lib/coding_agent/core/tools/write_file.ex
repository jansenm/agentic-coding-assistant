defmodule CodingAgent.Core.Tools.WriteFile do
  @moduledoc """
  Whole-file write tool (slice 2b; ADR 030).

  The write is a confined `tee` through `Tools.FileExec`: the content
  goes on the process's stdin and the sandbox profile is the boundary.
  A path the profile hides or binds read-only fails at the write
  (`EROFS`), by construction. Allow-by-policy (ADR 010 amendment,
  2026-09-15) still applies, and a repo or user policy file can turn
  write_file into ask/deny per path (`[permissions.write_file]
  "config/**" = "ask"`).
  """

  alias CodingAgent.Core.Tools

  @timeout_secs 30

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "write_file",
      description:
        "Create or overwrite a text file. " <>
          "Auto-approved by policy unless a permissions file tightens it.",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to write (relative paths resolve against the session scope root)"
        ],
        content: [type: :string, required: true, doc: "Full file content to write"]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  defp execute(scope, args) do
    path = Map.get(args, :path) || Map.get(args, "path")
    content = Map.get(args, :content) || Map.get(args, "content") || ""

    if is_binary(path) and path != "" do
      content = if is_binary(content), do: content, else: ""
      case Tools.FileExec.write(scope, path, content, @timeout_secs) do
        {:ok, _path} -> {:ok, "wrote #{path} (#{String.length(content)} chars)"}
        {:error, message} -> Tools.error(message)
      end
    else
      Tools.error("path must be a non-empty string")
    end
  end
end
