defmodule CodingAgent.Core.Tools do
  @moduledoc """
  Tool registry (slice 2a): the tools a session may use, as plain data.

  Per ADR 007 and the roadmap policy layer, a tool definition carries a
  `scope` alongside its name/description/schema. The permission gate
  governs state-changing tools (slice 2b); since ADR 030 the sandbox
  profile is what confines what every tool can reach.

  Tools are plain `ReqLLM.Tool` structs (req_llm streams, validates and
  schema-encodes them); this module only owns their construction and
  the tool registry.

  ADR 030: the **sandbox profile** is the one boundary. The native file
  tools run as confined processes (`Tools.FileExec`); `shell`/`git` and
  the `grep`/`glob` delegations run through `Core.Exec` under the same
  profile abstraction. `Tools.in_scope?/2` remains as a *discovery*
  filter (re-checking an engine's returned paths) — no tool relies on it
  for enforcement any more.
  """

  alias CodingAgent.Core.Tools.Edit
  alias CodingAgent.Core.Tools.Git
  alias CodingAgent.Core.Tools.Glob
  alias CodingAgent.Core.Tools.Grep
  alias CodingAgent.Core.Tools.ListDir
  alias CodingAgent.Core.Tools.ReadFile
  alias CodingAgent.Core.Tools.Question
  alias CodingAgent.Core.Tools.Shell
  alias CodingAgent.Core.Tools.TodoWrite
  alias CodingAgent.Core.Tools.WebFetch
  alias CodingAgent.Core.Tools.WriteFile

  @typedoc """
  A tool scope: the root directory the tool may operate in, the resolved
  mount schema, and the owning session id (ADR 022 — the id lets a
  confined tool bind a session-persistent scratch over `/tmp`; absent
  when there is no session).
  """
  @type scope :: %{
          required(:root) => String.t(),
          optional(:mounts) => CodingAgent.Core.Sandbox.Mounts.t(),
          optional(:session_id) => String.t() | nil,
          optional(:shell_mode) => CodingAgent.Core.Permissions.shell_mode(),
          optional(:depth) => non_neg_integer(),
          optional(:subagents) => [%{name: String.t(), description: String.t() | nil}]
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

    [
      ListDir.tool(scope),
      ReadFile.tool(scope),
      Grep.tool(scope),
      Glob.tool(scope),
      # asking is read-only, and the session intercepts the call before
      # execution (ADR 027); available to every agent including plan
      Question.tool(scope),
      # pure session state, intercepted before execution (ADR 031);
      # available to every agent including plan
      TodoWrite.tool(scope)
    ]
  end

  @doc """
  State-changing tools; always executed behind the permission gate.

  Since ADR 030 a session only exists under a confining sandbox, so the
  gate allows `shell`/`git` by default (only a stated escalation, e.g.
  `network`, asks). `git` runs with `.git` writable through its own
  sandbox profile; both are policy-configurable (`[permissions.shell]`
  etc.).
  """
  @spec gated(scope() | nil) :: [ReqLLM.Tool.t()]
  def gated(scope \\ nil) do
    scope = scope || default_scope()

    [
      WriteFile.tool(scope),
      Edit.tool(scope),
      Shell.tool(scope),
      Git.tool(scope),
      WebFetch.tool(scope)
    ]
  end

  @doc "All tools a session carries (read-only + gated + delegation)."
  @spec all(scope() | nil) :: [ReqLLM.Tool.t()]
  def all(scope \\ nil), do: read_only(scope) ++ gated(scope) ++ delegation(scope)

  @doc """
  Delegation tools (the `task` tool, ADR 017/018).

  Only a **primary** session (depth 0) may delegate: a subagent is depth
  1 and gets an empty list, which enforces the depth-1 fan-out bound at
  the same place the registry is narrowed. The gate intercepts a `task`
  call before execution (`Core.Session.Subagent`), so the callback here
  is a safety net.
  """
  @spec delegation(scope() | nil) :: [ReqLLM.Tool.t()]
  def delegation(scope \\ nil) do
    scope = scope || default_scope()

    if is_map(scope) and Map.get(scope, :depth, 0) == 0 do
      [CodingAgent.Core.Tools.Task.tool(scope)]
    else
      []
    end
  end

  @doc """
  Default scope: the process working directory.
  """
  @spec default_scope() :: scope()
  def default_scope do
    %{root: File.cwd!()}
  end

  @doc """
  The sandbox profile for the native file tools and the read-only
  delegations (`grep`/`glob`): the scope root plus its configured mounts,
  no network and no `.git` write.

  ADR 030: this is the ONE profile for every non-git tool. A read-only
  agent (`shell_mode: :ro`, e.g. the plan agent) gets `root_ro: true`, so
  the profile itself refuses writes — the tool list is not relied on as
  an enforcement boundary.
  """
  @spec profile(scope()) :: CodingAgent.Core.Sandbox.profile()
  def profile(scope) do
    mounts = Map.get(scope, :mounts) || CodingAgent.Core.Sandbox.Mounts.empty()

    %{
      root: Map.fetch!(scope, :root),
      network: false,
      git_write: false,
      root_ro: Map.get(scope, :shell_mode) == :ro,
      scratch: CodingAgent.Core.Session.Scratch.from_scope(scope),
      rw: Map.get(mounts, :rw, []),
      ro: Map.get(mounts, :ro, []),
      hide: Map.get(mounts, :hide, [])
    }
  end

  @doc """
  Whether a path lies inside the scope tree — a DISCOVERY predicate
  (ADR 030), not a boundary.

  Used to filter enumerator output (a `grep`/`glob` result the search
  engine produced) and to anchor a relative path. Enforcement is the
  sandbox profile; do not treat a `true` here as permission to touch the
  path.

  `..` traversal must not leave `scope.root`, and **symlinks are
  resolved physically** before the check — a link inside the scope
  pointing outside it is rejected (a symlinked root itself is fine: the
  root is resolved first). That is what makes the result filter honest:
  an out-of-scope symlink's target can never be REPORTED, even if the
  engine read it.
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
