defmodule CodingAgent.Core.Tools.WriteFile do
  @moduledoc """
  State-changing file write tool (slice 2b). Always subject to the
  permission gate; never listed in the read-only registry.
  """

  alias CodingAgent.Core.Tools

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "write_file",
      description:
        "Create or overwrite a text file inside the session scope. " <>
          "Subject to the permission policy; may require approval.",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "Relative or absolute path within the session scope"
        ],
        content: [type: :string, required: true, doc: "Full file content to write"]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  defp execute(scope, args) do
    path = Map.get(args, :path) || Map.get(args, "path")
    content = Map.get(args, :content) || Map.get(args, "content") || ""

    with :ok <- check_scope(scope, path),
         :ok <- do_write(scope, path, content) do
      {:ok, "wrote #{path} (#{String.length(content)} chars)"}
    end
  end

  defp check_scope(scope, path) do
    if Tools.in_scope?(scope, path) do
      :ok
    else
      Tools.error("path escapes the session scope: #{inspect(path)}")
    end
  end

  defp do_write(scope, path, content) do
    file = Path.expand(path, Path.expand(scope.root))

    case File.write(file, content) do
      :ok ->
        :ok

      {:error, reason} ->
        Tools.error("cannot write #{path}: #{:file.format_error(reason)}")
    end
  end
end
