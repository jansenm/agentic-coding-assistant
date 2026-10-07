defmodule CodingAgent.Core.Tools.WriteFile do
  @moduledoc """
  Whole-file write tool (slice 2b; ADR 045; ADR 030).

  The write is a confined `tee` through `Tools.FileExec`: the content
  goes on the process's stdin and the sandbox profile is the boundary.
  A path the profile hides or binds read-only fails at the write
  (`EROFS`), by construction. Allow-by-policy (ADR 010 amendment,
  2026-09-15) still applies, and a repo or user policy file can turn
  write_file into ask/deny per path (`[permissions.write_file]
  "config/**" = "ask"`).

  ## `parents`

  `tee` does not create a directory (measured: `No such file or
  directory`), so a write into a missing parent fails. With `parents:
  true` the parent is created first through a confined `mkdir
  --parents` — which also makes an EXISTING parent a no-op, so the flag
  is idempotent. The default is `false`, and a failure then names the
  flag instead of leaving the program's bare message: the tool checks
  whether the parent exists (a confined `ls`, never a BEAM `File.stat`)
  and, when it does not, says so and names `parents: true`. Only for a
  genuinely missing parent — a `ro`/`hidden` path fails with the
  program's own message, which is the honest one.
  """

  alias CodingAgent.Core.Tools

  @timeout_secs 30

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "write_file",
      description:
        "Create or overwrite a text file. " <>
          "The parent directory must exist; pass `parents: true` to create " <>
          "it (and any missing chain) first. " <>
          "Auto-approved by policy unless a permissions file tightens it.",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to write (relative paths resolve against the session scope root)"
        ],
        content: [type: :string, required: true, doc: "Full file content to write"],
        parents: [
          type: :boolean,
          required: false,
          doc: "Pass `--parents` to mkdir: create a missing parent directory first"
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  defp execute(scope, args) do
    path = Map.get(args, :path) || Map.get(args, "path")
    content = Map.get(args, :content) || Map.get(args, "content") || ""
    parents = Map.get(args, :parents) || Map.get(args, "parents") || false

    if is_binary(path) and path != "" do
      content = if is_binary(content), do: content, else: ""

      with :ok <- maybe_make_parent(scope, path, parents) do
        case Tools.FileExec.write(scope, path, content, @timeout_secs) do
          {:ok, _path} -> {:ok, "wrote #{path} (#{String.length(content)} chars)"}
          {:error, message} -> Tools.error(parent_hint(scope, path, message))
        end
      end
    else
      Tools.error("path must be a non-empty string")
    end
  end

  # `parents: true`: `mkdir --parents` the parent of `path`. Idempotent
  # (an existing directory exits 0), and it fails loudly on a FILE in the
  # way. A path with no directory part (a bare file name) has nothing to
  # create — `mkdir --parents` on "." is a measured no-op.
  defp maybe_make_parent(_scope, _path, false), do: :ok

  defp maybe_make_parent(scope, path, true) do
    dir = Path.dirname(path)

    case Tools.FileExec.mkdir(scope, dir, @timeout_secs) do
      {:ok, _dir} -> :ok
      {:error, message} -> Tools.error(message)
    end
  end

  # The bare `tee` failure ("No such file or directory") does not say
  # WHICH part is missing or how to fix it. When the parent is the
  # missing part, say so and name the parameter — the confinement rule
  # forbids a BEAM stat, so the probe is a confined `ls`.
  defp parent_hint(scope, path, message) do
    dir = Path.dirname(path)

    if dir != "." and Tools.FileExec.stat(scope, dir, @timeout_secs) == :missing do
      message <>
        "; the parent directory #{dir} does not exist — pass `parents: true` to create it"
    else
      message
    end
  end
end
