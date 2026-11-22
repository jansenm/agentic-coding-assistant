# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.Escalation do
  @moduledoc """
  The coarse **escalations** of ADR 015: `network` and `change_vcs`.

  A tool call may state them as booleans; each widens the sandbox profile
  beyond what the scope already grants, so each re-enables the permission
  prompt even under confinement and each requires a `reason` the human
  reads before answering. They are never inferred from command text — the
  agent states its intent, the human decides.

  The schema keywords, the readers and the verdict live here rather than in
  the two tools that use them (`Shell`, `Git`), because the gate asks every
  call the same question: which escalations does it state, and is the
  request answerable? A second escalation-carrying tool must not mean a
  second copy of "the reason is required" in the gate.

  `shell` states both. The `git` tool grants `change_vcs` unconditionally
  (ADR 015 decision 4), so the same keyword there widens only the network —
  which is what `git fetch`/`clone`/`push` need. The verdict does not care:
  a call that states an escalation without a reason is refused wherever it
  came from.

  Named `change_vcs`, not `git_write` (2026-10-22): the grant is about the
  repository's VERSION CONTROL state — index, objects, refs — which is
  already phrased VCS-neutrally in the sandbox profile, and which for a
  worktree or a subdirectory session is not "the `.git` in the scope" at
  all. A future second VCS then widens the same grant rather than adding a
  synonym.
  """

  @escalations [:network, :change_vcs]

  @typedoc "An escalation keyword as it appears in a tool's parameter schema."
  @type name :: :network | :change_vcs

  @doc "Every escalation keyword, in schema order."
  @spec all() :: [name()]
  def all, do: @escalations

  @doc "The keywords `schema` declares, in `all/0` order."
  @spec of(keyword() | map() | term()) :: [name()]
  def of(schema) when is_list(schema) do
    Enum.filter(all(), &Keyword.has_key?(schema, &1))
  end

  def of(%{} = schema), do: Enum.filter(all(), &Map.has_key?(schema, &1))
  def of(_schema), do: []

  @doc """
  The escalations a call states, e.g. `[:network, :change_vcs]`. Coarse
  booleans only: `false`, `nil` and a missing key all mean "not requested".
  """
  @spec requested(term(), [name()]) :: [name()]
  def requested(args, allowed \\ @escalations)

  def requested(args, allowed) when is_map(args) do
    Enum.filter(allowed, fn key ->
      truthy?(Map.get(args, key) || Map.get(args, to_string(key)))
    end)
  end

  def requested(_args, _allowed), do: []

  @doc """
  Whether `args` states this one escalation. Same coarse booleans as
  `requested/2`; this is the reader a profile builder uses for one keyword.
  """
  @spec granted?(term(), name()) :: boolean()
  def granted?(args, key), do: requested(args, [key]) != []

  @doc """
  Whether a call requests an escalation the tool's schema actually declares.
  A keyword the tool does not offer is not an escalation — `shell` has no
  way to widen a file tool's profile.
  """
  @spec requested?(term(), keyword() | map() | term()) :: boolean()
  def requested?(args, schema), do: requested(args, of(schema)) != []

  @doc """
  The agent's stated reason for an escalation, or `nil`. Every escalation
  must carry one: the human sees *why* before approving, not just a bare
  boolean. `reason` may be supplied for any call; it is only required when
  an escalation is requested.
  """
  @spec reason(term()) :: String.t() | nil
  def reason(args) when is_map(args) do
    case Map.get(args, :reason) || Map.get(args, "reason") do
      r when is_binary(r) ->
        case String.trim(r) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def reason(_args), do: nil

  @doc """
  The escalation gate verdict: `:ok`, or `{:error, guidance}` when a stated
  escalation has no reason. The reason is not security theatre — it is what
  the human reads in the approval dialog, and refusing a bare boolean keeps
  the prompt answerable.

  The message names the *reason* and the escalation it belongs to; it does
  not repeat the whole feature, because it is also the tool result an agent
  reads mid-turn (see the redirect hint in `Shell` for the same discipline).
  """
  @spec verdict(term(), [name()]) :: :ok | {:error, String.t()}
  def verdict(args, allowed \\ @escalations) do
    case requested(args, allowed) do
      [] ->
        :ok

      keys ->
        if reason(args) == nil do
          {:error,
           "an escalation (#{Enum.map_join(keys, "/", &to_string/1)}) must include `reason`: " <>
             "one short sentence explaining why this call needs it — the human sees it in " <>
             "the approval prompt and a bare request is refused"}
        else
          :ok
        end
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false
end
