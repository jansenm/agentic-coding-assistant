# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.ToolCall do
  @moduledoc """
  Normalizes a tool call to `{id, name, args}` regardless of where it
  came from.

  Tool calls arrive in three shapes and every consumer must treat them
  the same:

    * `%ReqLLM.ToolCall{}` — the struct form, `arguments` a JSON string;
    * a plain map with `:arguments` already decoded (stream events);
    * a plain map with only `:id`/`:name` (no arguments).

  Before this module the same clauses were copied in `Session`
  (`call_parts/1`), the CLI (`call_info/1`) and the TUI (`call_info/1`) —
  and the CLI's own comment pointed at the session's copy by name. One
  implementation, one set of edge cases.
  """

  @typedoc "A normalized call: id, tool name, decoded argument map."
  @type normalized :: {String.t() | nil, String.t(), map()}

  @doc """
  Normalizes `call` to `{id, name, args}`. A binary arguments field is
  JSON-decoded; malformed JSON becomes `%{}` (the tool's own validation
  reports the real problem), never a crash.
  """
  @spec normalize(term()) :: normalized()
  def normalize(%ReqLLM.ToolCall{id: id, function: %{name: name, arguments: args}}),
    do: {id, name, decode(args)}

  def normalize(%{id: id, name: name, arguments: args}),
    do: {id, name, decode(args)}

  def normalize(%{id: id, name: name}), do: {id, name, %{}}

  def normalize(%{id: id, function: %{name: name, arguments: args}}),
    do: {id, name, decode(args)}

  @doc """
  Decodes a tool-call arguments value: a map passes through, a binary is
  JSON-decoded (malformed -> `%{}`), anything else -> `%{}`.
  """
  @spec decode(term()) :: map()
  def decode(args) when is_map(args), do: args

  def decode(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  def decode(_), do: %{}
end
