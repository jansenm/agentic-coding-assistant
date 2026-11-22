# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.MoveFile do
  @moduledoc """
  Path move/rename tool (ADR 045; ADR 030).

  The move is a confined `mv` through `Tools.FileExec`, so the sandbox
  profile is the boundary. `-T` is always on: `to` is the exact new path,
  never a directory to move into (a move *into* a directory is written as
  the full target path). By default an existing destination is NOT
  overwritten — the tool probes it and refuses, naming `force`, rather
  than letting `--no-clobber` report a silent success; `force: true`
  overwrites. A symlink moves as a link — `mv` never dereferences.

  Allow-by-policy like the other contained write tools (ADR 010
  amendment, 2026-09-15); a policy file can tighten it per path. A move
  touches two paths, and the gate evaluates BOTH (`Core.Session.Gate`),
  so a deny on either end refuses the call.
  """

  alias CodingAgent.Core.Tools

  @timeout_secs 30

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "move_file",
      description:
        "Move or rename a path. `to` is the EXACT new path (mv -T): it is " <>
          "never treated as a directory to move into — to move a file into a " <>
          "directory, name the full target path. By default an existing " <>
          "destination is NOT overwritten (mv --no-clobber); set `force: true` " <>
          "to overwrite. A symlink moves as the LINK, never its target. " <>
          "Auto-approved by policy unless a permissions file tightens it.",
      parameter_schema: [
        from: [type: :string, required: true, doc: "Path to move"],
        to: [type: :string, required: true, doc: "Exact destination path"],
        force: [
          type: :boolean,
          required: false,
          doc: "Pass `--force`: overwrite an existing destination (default false)"
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  defp execute(scope, args) do
    from = Map.get(args, :from) || Map.get(args, "from")
    to = Map.get(args, :to) || Map.get(args, "to")
    force = Map.get(args, :force) || Map.get(args, "force") || false

    cond do
      not is_binary(from) or from == "" ->
        Tools.error("from must be a non-empty string")

      not is_binary(to) or to == "" ->
        Tools.error("to must be a non-empty string")

      true ->
        with :ok <- destination_free(scope, to, force) do
          case Tools.FileExec.move(scope, from, to, [force: force], @timeout_secs) do
            {:ok, _to} -> {:ok, "moved #{from} to #{to}"}
            {:error, message} -> Tools.error(message)
          end
        end
    end
  end

  # `mv --no-clobber` on an existing destination exits 0 WITHOUT stderr —
  # a "successful" call that did nothing, which the model cannot tell from
  # a real move. The probe turns that into a clear refusal that names the
  # way out; `--no-clobber` stays on as a second barrier (a race between
  # the probe and the process cannot overwrite).
  defp destination_free(_scope, _to, true), do: :ok

  defp destination_free(scope, to, false) do
    case Tools.FileExec.stat(scope, to, @timeout_secs) do
      :missing ->
        :ok

      _exists ->
        Tools.error("destination already exists: #{inspect(to)}; pass `force: true` to overwrite")
    end
  end
end
