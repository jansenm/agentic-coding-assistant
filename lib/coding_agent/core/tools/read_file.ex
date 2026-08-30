defmodule CodingAgent.Core.Tools.ReadFile do
  @moduledoc """
  Read-only file content tool (slice 2a).
  """

  alias CodingAgent.Core.Tools

  @max_bytes 256 * 1024

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "read_file",
      description:
        "Read a text file inside the session scope. " <>
          "Returns the file content; files larger than 256 KiB are rejected.",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "Relative or absolute path within the session scope"
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  defp execute(scope, args) do
    path = Map.get(args, :path) || Map.get(args, "path")

    with :ok <- check_scope(scope, path),
         {:ok, content} <- do_read(scope, path) do
      {:ok, content}
    end
  end

  defp check_scope(scope, path) do
    if Tools.in_scope?(scope, path) do
      :ok
    else
      Tools.error("path escapes the session scope: #{inspect(path)}")
    end
  end

  defp do_read(scope, path) do
    file = Path.expand(path, Path.expand(scope.root))

    cond do
      not File.regular?(file) ->
        Tools.error("not a file: #{path}")

      not readable?(file) ->
        Tools.error("cannot read #{path}: file is not readable")

      true ->
        case File.read(file) do
          {:ok, bytes} when byte_size(bytes) <= @max_bytes ->
            {:ok, bytes}

          {:ok, _bytes} ->
            Tools.error("file larger than 256 KiB: #{path}")

          {:error, reason} ->
            Tools.error("cannot read #{path}: #{:file.format_error(reason)}")
        end
    end
  end

  defp readable?(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.access in [:read, :read_write]
      {:error, _} -> false
    end
  end
end
