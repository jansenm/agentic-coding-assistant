defmodule CodingAgent.Core.Tools.ListDir do
  @moduledoc """
  Read-only directory listing tool (slice 2a).
  """

  alias CodingAgent.Core.Tools

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "list_dir",
      description:
        "List the entries of a directory inside the session scope. " <>
          "Returns names, one per line, directories marked with a trailing slash.",
      parameter_schema: [
        path: [
          type: :string,
          required: false,
          default: ".",
          doc: "Relative or absolute path within the session scope"
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  defp execute(scope, args) do
    path = Map.get(args, :path) || Map.get(args, "path") || "."

    with :ok <- check_scope(scope, path),
         {:ok, entries} <- do_list(scope, path) do
      {:ok, entries}
    end
  end

  defp check_scope(scope, path) do
    if Tools.in_scope?(scope, path) do
      :ok
    else
      Tools.error("path escapes the session scope: #{inspect(path)}")
    end
  end

  defp do_list(scope, path) do
    dir = Path.expand(path, Path.expand(scope.root))

    case File.ls(dir) do
      {:ok, entries} ->
        lines =
          entries
          |> Enum.sort()
          |> Enum.map(fn entry ->
            if File.dir?(Path.join(dir, entry)), do: entry <> "/", else: entry
          end)

        {:ok, Enum.join(lines, "\n")}

      {:error, reason} ->
        Tools.error("cannot list #{path}: #{:file.format_error(reason)}")
    end
  end
end
