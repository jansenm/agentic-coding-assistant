# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.ReadFile do
  @moduledoc """
  Read-only file content tool (slice 2a).

  ADR 030: the read is a confined `cat` through `Tools.FileExec`, not a
  BEAM `File.read/1`. What the tool can reach is exactly what the session
  profile exposes — a `hide`d path reads the notice file the sandbox
  binds over it, `ro` binds are readable, and the whole read-only root is
  available. There is no second scope predicate at this layer.
  """

  alias CodingAgent.Core.Tools

  @max_bytes 256 * 1024
  @timeout_secs 30
  # A window without a limit defaults to this many lines (a page).
  @default_limit 200

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "read_file",
      description:
        "Read a text file. Returns the file content; files larger than " <>
          "256 KiB are rejected. To read a large file (or a spilled tool " <>
          "output named in a truncation note), pass `offset` and `limit` " <>
          "to read a line window instead — the whole-file cap does not " <>
          "apply to a window.",
      parameter_schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to read (relative paths resolve against the session scope root)"
        ],
        offset: [
          type: :integer,
          required: false,
          doc:
            "1-based first line to read (default 1; requires `limit` when given; omit both for the whole file)"
        ],
        limit: [
          type: :integer,
          required: false,
          doc:
            "Number of lines to read from `offset` (or the first `limit` lines when `offset` is omitted; default 200)"
        ]
      ],
      callback: fn args -> execute(scope, args) end
    )
  end

  defp execute(scope, args) do
    path = Map.get(args, :path) || Map.get(args, "path")
    offset = Map.get(args, :offset) || Map.get(args, "offset")
    limit = Map.get(args, :limit) || Map.get(args, "limit")

    cond do
      not is_binary(path) or path == "" ->
        Tools.error("path must be a non-empty string")

      offset == nil and limit == nil ->
        whole(scope, path)

      true ->
        window(scope, path, offset, limit)
    end
  end

  defp whole(scope, path) do
    case Tools.FileExec.read(scope, path, @timeout_secs, @max_bytes) do
      {:ok, content} -> {:ok, content}
      {:error, message} -> Tools.error(message)
    end
  end

  defp window(scope, path, offset, limit) do
    # `limit` alone means "the first N lines": offset defaults to 1. An
    # explicit offset is still validated (0/negative is a real error), so
    # `offset || 1` only fills the absent case (0 is truthy in Elixir).
    with {:ok, offset} <- positive(offset || 1, "offset"),
         limit <- if(limit == nil, do: @default_limit, else: limit),
         {:ok, limit} <- positive(limit, "limit") do
      case Tools.FileExec.read_window(scope, path, offset, limit, @timeout_secs) do
        {:ok, content, total} ->
          {:ok, content <> window_note(offset, limit, total)}

        {:error, message} ->
          Tools.error(message)
      end
    end
  end

  defp positive(n, _name) when is_integer(n) and n > 0, do: {:ok, n}

  defp positive(n, name) when is_binary(n) do
    case Integer.parse(n) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> Tools.error("#{name} must be a positive integer")
    end
  end

  defp positive(_n, name), do: Tools.error("#{name} must be a positive integer")

  # The paging footer: how much was shown and what remains, so the model
  # can ask for the next window (ADR 038). A file with no lines at all
  # gets a plain "empty" note rather than "lines 1-0 of 0".
  defp window_note(_offset, _limit, 0), do: "\n[... file has no lines ...]"

  defp window_note(offset, limit, total) when is_integer(total) do
    shown_end = min(offset + limit - 1, total)

    more = if shown_end < total, do: "; read on with offset #{shown_end + 1}", else: ""

    "\n[... lines #{offset}-#{shown_end} of #{total}#{more} ...]"
  end
end
