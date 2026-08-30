defmodule CodingAgent.Core.Tools do
  @moduledoc """
  Tool registry (slice 2a): the tools a session may use, as plain data.

  Per ADR 007 and the roadmap policy layer, a tool definition carries a
  `scope` alongside its name/description/schema; 2a tools are read-only
  and therefore allow-by-policy (no gate) — the scope plus path-escape
  checks still confine *what* they can read. The permission gate
  governs state-changing tools from slice 2b.

  Tools are plain `ReqLLM.Tool` structs (req_llm streams, validates and
  schema-encodes them); this module only owns their construction and
  the read-only policy boundary.
  """

  alias CodingAgent.Core.Tools.ListDir
  alias CodingAgent.Core.Tools.ReadFile

  @type scope :: %{
          required(:root) => String.t()
        }

  @doc """
  Read-only tools enabled for phase 2a sessions.

  Every tool here is read-only by construction; the registry is THE
  policy point for that guarantee (a tool that writes must never be
  listed here and must not bypass the permission gate, slice 2b).
  """
  @spec read_only(scope() | nil) :: [ReqLLM.Tool.t()]
  def read_only(scope \\ nil) do
    scope = scope || default_scope()
    [ListDir.tool(scope), ReadFile.tool(scope)]
  end

  @doc """
  Default scope: the process working directory.
  """
  @spec default_scope() :: scope()
  def default_scope do
    %{root: File.cwd!()}
  end

  @doc """
  Resolves a path against the scope root and rejects escapes.

  Read-only tools are safe only as long as the path they touch stays
  inside the scope; `..` traversal must not leave `scope.root`.
  Returns the absolute, normalized path (or the original relative one
  when the calling tool wants that).
  """
  @spec in_scope?(scope(), String.t()) :: boolean()
  def in_scope?(scope, path) do
    root = Path.expand(scope.root)

    expanded =
      path
      |> Path.expand(root)
      |> Path.expand()

    String.starts_with?(expanded <> "/", root <> "/") or expanded == root
  end

  @doc """
  Formats a tool execution error the way the model should see it.
  """
  @spec error(String.t()) :: {:error, String.t()}
  def error(message), do: {:error, message}
end
