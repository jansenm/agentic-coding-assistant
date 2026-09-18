defmodule CodingAgent.Core.Tools.WriteFile do
  @moduledoc """
  Whole-file write tool (slice 2b). Allow-by-policy (ADR 010
  amendment, 2026-09-15): the fence is structural, not social —
  contained paths (physically resolved, `check_scope`) and every
  landed change reviewable as a VCS diff. A repo or user policy file
  can still turn write_file into ask/deny per path
  (`[permissions.write_file] "config/**" = "ask"`).
  """

  alias CodingAgent.Core.Containment
  alias CodingAgent.Core.Tools

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "write_file",
      description:
        "Create or overwrite a text file inside the session scope. " <>
          "Auto-approved by policy for in-scope paths unless a " <>
          "permissions file tightens it.",
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

    with :ok <- Containment.check_scope!(scope, path),
         :ok <- do_write(scope, path, content) do
      {:ok, "wrote #{path} (#{String.length(content)} chars)"}
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
