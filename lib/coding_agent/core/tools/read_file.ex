defmodule CodingAgent.Core.Tools.ReadFile do
  @moduledoc """
  Read-only file content tool (slice 2a).

  ADR 030: the read is a confined `cat` through `Tools.FileExec`, not a
  BEAM `File.read/1`. What the tool can reach is exactly what the session
  profile exposes — `hide`d paths read as the empty image, `ro` binds are
  readable, and the whole read-only root is available. There is no second
  scope predicate at this layer.
  """

  alias CodingAgent.Core.Tools

  @max_bytes 256 * 1024
  @timeout_secs 30

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "read_file",
      description:
        "Read a text file. " <>
          "Returns the file content; files larger than 256 KiB are rejected.",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to read (relative paths resolve against the session scope root)"
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  defp execute(scope, args) do
    path = Map.get(args, :path) || Map.get(args, "path")

    if is_binary(path) and path != "" do
      case Tools.FileExec.read(scope, path, @timeout_secs, @max_bytes) do
        {:ok, content} -> {:ok, content}
        {:error, message} -> Tools.error(message)
      end
    else
      Tools.error("path must be a non-empty string")
    end
  end
end
