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

  alias CodingAgent.Core.Tools.Glob
  alias CodingAgent.Core.Tools.Grep
  alias CodingAgent.Core.Tools.ListDir
  alias CodingAgent.Core.Tools.ReadFile
  alias CodingAgent.Core.Tools.Shell
  alias CodingAgent.Core.Tools.WriteFile

  @typedoc "A tool scope: the root directory the tool may operate in."
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
    [ListDir.tool(scope), ReadFile.tool(scope), Grep.tool(scope), Glob.tool(scope)]
  end

  @doc """
  State-changing tools; always executed behind the permission gate.

  `shell` has no path containment by design (ADR 010): a shell
  trivially bypasses file checks, so it is gated on *every* call —
  there is no policy way to allow it in v1.
  """
  @spec gated(scope() | nil) :: [ReqLLM.Tool.t()]
  def gated(scope \\ nil) do
    scope = scope || default_scope()
    [WriteFile.tool(scope), Shell.tool(scope)]
  end

  @doc "All tools a session carries (read-only + gated)."
  @spec all(scope() | nil) :: [ReqLLM.Tool.t()]
  def all(scope \\ nil), do: read_only(scope) ++ gated(scope)

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
  inside the scope; `..` traversal must not leave `scope.root`, and
  **symlinks are resolved physically** before the check — a link inside
  the scope pointing outside it is rejected (a symlinked root itself is
  fine: the root is resolved first).

  Returns true when access should be permitted.
  """
  @spec in_scope?(scope(), String.t()) :: boolean()
  def in_scope?(scope, path) do
    root = physical_path(Path.expand(scope.root))

    candidate = Path.expand(path, root)

    # Resolve the candidate physically: dot-dot segments are already
    # normalized by expand, and physical_path follows any symlinks
    # (final or ancestor) to their real target.
    resolved = physical_path(candidate)

    String.starts_with?(resolved <> "/", root <> "/") or resolved == root
  end

  # Physical path resolution: walk every component from the filesystem
  # root, following symlinks (including symlinked *directories* inside
  # the path). Returns the fully-resolved path; dangling links are
  # followed textually as far as possible.
  defp physical_path(path, hops \\ 0) do
    # realpath-style resolution: walk components from the root; when a
    # component is a symlink, restart resolution with the link target
    # followed by all remaining segments (handles chains, and links
    # whose targets contain further links). Dangling links continue
    # textually; the scope check still applies and execution fails
    # naturally on the missing file.
    if hops > 16 do
      raise ArgumentError, "too many symlink hops resolving #{inspect(path)}"
    end

    walk_segments(split_path(Path.expand(path, "/")), "/", hops)
  end

  defp walk_segments([], acc, _hops), do: acc

  defp walk_segments([seg | rest], acc, hops) do
    next = Path.join(acc, seg)

    case :file.read_link_info(String.to_charlist(next)) do
      {:ok, info} when elem(info, 2) == :symlink ->
        case :file.read_link(String.to_charlist(next)) do
          {:ok, target} ->
            target_str = List.to_string(target)

            base =
              if Path.type(target_str) == :absolute,
                do: target_str,
                else: Path.expand(target_str, acc)

            # target + everything not yet walked, resolved as one path
            physical_path(Enum.join([base | rest], "/"), hops + 1)

          {:error, _} ->
            # dangling link: continue textually with the remaining path
            Enum.reduce(rest, next, &Path.join(&2, &1))
        end

      _ ->
        walk_segments(rest, next, hops)
    end
  end

  defp split_path(path) do
    path
    |> Path.split()
    |> Enum.reject(&(&1 in ["/", "."]))
  end

  @doc """
  Formats a tool execution error the way the model should see it.
  """
  @spec error(String.t()) :: {:error, String.t()}
  def error(message), do: {:error, message}
end
