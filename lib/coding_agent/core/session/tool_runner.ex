# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.ToolRunner do
  @moduledoc """
  Tool execution for one session round, extracted from `Session`.

  Owns the two things that are not policy: which tools the session
  exposes (the registry narrowed by the policy's enabled/disabled sets)
  and how each call is executed, sequentially, honoring a user stop
  between calls. The permission decision itself belongs to
  `CodingAgent.Core.Session.Gate`.
  """

  alias CodingAgent.Core.{Interrupt, Permissions, Sandbox}
  alias CodingAgent.Core.Text
  alias CodingAgent.Core.ToolCall

  @doc """
  The tools a session exposes: the full registry, narrowed by
  `[tools] enabled` (a real whitelist; empty = every tool) and by the
  agent definition's `disallowedTools` (ADR 017).
  """
  @spec tools(Permissions.t(), CodingAgent.Core.Tools.scope()) :: [ReqLLM.Tool.t()]
  def tools(policy, scope) do
    all = CodingAgent.Core.Tools.all(scope)

    narrowed =
      case Permissions.enabled(policy) do
        :default -> all
        names -> Enum.filter(all, &(&1.name in names))
      end

    case Permissions.disabled(policy) do
      [] -> narrowed
      disabled -> Enum.reject(narrowed, &(&1.name in disabled))
    end
  end

  @doc """
  Executes `calls` in order under `tools`. A stop requested between two
  calls is honored: already-run tools keep their real result, everything
  after gets a synthetic result (the exchange still needs one result per
  call to stay valid on the wire). Mid-tool cancellation is out of scope
  — see `CodingAgent.Core.Interrupt`.
  """
  @spec execute(String.t(), [ReqLLM.Tool.t()], [term()]) :: [map()]
  def execute(session_id, tools, calls) do
    {results, _stopped?} =
      Enum.reduce(calls, {[], false}, fn call, {acc, stopped?} ->
        {id, name, args} = ToolCall.normalize(call)
        # `arguments` rides along on the result so the display view can
        # record what a tool was ASKED to do (a transcript that shows only
        # the output — "read_file -> text" — cannot say which file).
        executing = %{id: id, name: name, arguments: args}

        cond do
          stopped? or Interrupt.requested?(session_id) ->
            {[Map.put(executing, :content, "error: stopped by the user") | acc], true}

          true ->
            # Announce THIS call immediately before it runs, so
            # start/result interleave correctly (started A, executed A,
            # started B, executed B). Announcing all starts up-front made
            # the status show the LAST call of the round while an earlier
            # one ran, and the result of A cleared B's label (review F2).
            CodingAgent.Core.Events.publish(session_id, {:tool_started, name})
            {[run_one(executing, name, args, tools) | acc], false}
        end
      end)

    Enum.reverse(results)
  end

  @doc "Executes one tool call, resolving it against the exposed registry."
  @spec run_one(map(), String.t(), map(), [ReqLLM.Tool.t()]) :: map()
  def run_one(executing, name, args, tools) do
    case Enum.find(tools, &(&1.name == name)) do
      nil ->
        # list the valid names: the model can self-correct in one round
        # (found live: GLM emitted tool calls named "assistant" —
        # provider-side mislabeling; with the names in the error it
        # retries with the right tool instead of spiraling)
        names = tools |> Enum.map(& &1.name) |> Enum.sort()

        Map.put(
          executing,
          :content,
          "error: unknown tool #{inspect(name)} — available tools: #{Enum.join(names, ", ")}"
        )

      tool ->
        case ReqLLM.Tool.execute(tool, args) do
          {:ok, output} -> Map.put(executing, :content, Text.to_text(output))
          {:error, msg} -> Map.put(executing, :content, "error: #{Text.to_text(msg)}")
        end
    end
  end

  @doc """
  The sandbox scope for a session: the scope root, its configured mounts,
  the session id (ADR 022 — the id lets the sandbox bind a
  session-persistent scratch over `/tmp`), the shell mode, plus the
  delegation fields (ADR 017/018): `depth` gates the `task` tool and
  `subagents` is what it advertises.
  """
  @spec scope(
          String.t() | nil,
          Sandbox.Mounts.t() | nil,
          String.t() | nil,
          Permissions.shell_mode(),
          keyword()
        ) :: CodingAgent.Core.Tools.scope()
  def scope(scope_root, mounts, session_id \\ nil, shell_mode \\ :rw, extras \\ []) do
    %{
      root: scope_root || File.cwd!(),
      mounts: mounts || Sandbox.Mounts.empty(),
      session_id: session_id,
      shell_mode: shell_mode,
      depth: Keyword.get(extras, :depth, 0),
      subagents: Keyword.get(extras, :subagents, [])
    }
  end
end
