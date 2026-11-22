# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Permissions do
  @moduledoc """
  The permission gate's data layer (ADR 010).

  A *policy* is plain data: per-tool glob tables plus tool enablement.
  Decisions are `:allow | :ask | :deny`; layers merge with the rule
  **most restrictive wins**; loading fails closed.

  Lookup for `effective/4` intersects (most restrictive of):

    * built-in class default (read-only tools allow, others ask)
    * user-level policy file
    * repo-side policy file
    * agent-definition entries (role `"default"` in slice 2b)

  Path patterns are globs matched against the path *relative to the
  scope root*. Dialect: `*` matches within one path segment, `**`
  spans segments, `?` matches one character, all else is literal.
  Among matching patterns, the most specific wins (by segment count);
  ties resolve to the more restrictive decision — which keeps the
  multi-layer merge order-independent.

  **`allow` is not a capability.** Matching is TEXTUAL
  (`Path.expand`); execution resolves physically (symlinks followed).
  The direction is safe — a deny can never be bypassed, because a
  physically-escaping path is rejected by Containment before it runs —
  but a `"tmp/**" = "allow"` pattern beside a `tmp -> /etc` symlink
  matches the call and then fails at execution with "path escapes the
  session scope". Read allow-patterns as "do not prompt", not "this
  path is writable".
  """

  @typedoc "A policy decision."
  @type decision :: :allow | :ask | :deny

  @typedoc "Pattern => decision entries for one tool."
  @type entries :: %{String.t() => decision()}

  @typedoc "One policy layer: per-tool entries."
  @type layer :: %{String.t() => entries()}

  @typedoc """
  How read-write `shell` is: `:rw` (the scope root is writable, today's
  behaviour) or `:ro` (allowed, but the sandbox binds the root read-only).
  Written in a policy/definition as `shell = "read_only"`.
  """
  @type shell_mode :: :rw | :ro

  @typedoc "A complete policy: merged layers + enablement."
  @type t :: %__MODULE__{
          entries: %{String.t() => entries()},
          enabled: [String.t()],
          disabled: [String.t()],
          shell_mode: shell_mode()
        }

  @enforce_keys [:entries, :enabled]
  defstruct entries: %{}, enabled: [], disabled: [], shell_mode: :rw

  # Class defaults when no policy entry matches. Read-only tools
  # allow-by-policy (slice 2a); every addition must be safe by
  # construction and contained (see Containment): grep/glob joined in
  # 2d; edit and write_file joined by the 2026-09-15 ADR 010 amendment
  # — contained (physically-resolved paths) and reviewable (every
  # landed change sits in the VCS diff). delete_file, move_file and
  # move_region joined under ADR 045 by the same test: they are confined
  # `rm`/`mv`
  # (ADR 030), and `shell` can already delete/move anything in the
  # scope — denying them here while `shell` is allow would be theatre.
  # shell and git joined with ADR 030: a session only exists under a
  # confining sandbox, so the profile is their boundary and they are
  # allow-by-default (an escalation, e.g. network, still asks).
  # webfetch stays ask (foreign content ingress; no sandbox profile
  # governs it).
  @allow_class [
    "list_dir",
    "read_file",
    "grep",
    "glob",
    "edit",
    "write_file",
    "delete_file",
    "move_file",
    "move_region",
    "shell",
    "git"
  ]

  @decisions ~w(allow ask deny)

  alias CodingAgent.Core.GlobMatch

  # -- Loading -----------------------------------------------------------------

  @doc """
  Loads the layered policy for a workspace. Fails closed: any
  malformed layer raises with the file named (never degrades to
  defaults). Missing files are fine.
  """
  @spec load(String.t() | nil, String.t() | nil) :: t()
  def load(user_file \\ nil, repo_file \\ nil) do
    user_layer = load_layer(user_file)
    repo_layer = load_layer(repo_file)

    %__MODULE__{
      entries: merge_layers([user_layer, repo_layer]),
      enabled: enabled_tools([user_layer, repo_layer]),
      shell_mode: merge_shell_mode([user_layer, repo_layer])
    }
  end

  @doc """
  Applies an agent definition (ADR 017 layer 4) on top of a loaded
  policy — **restrictive only**, exactly like the other layers:

  * its `permission` table is merged with most-restrictive-wins;
  * its `tools` allow-list and `disallowedTools` deny-list narrow the
    enabled set. When the definition names tools, the effective enabled
    set is the *intersection* with whatever the policy already allowed,
    so a definition can never re-enable a tool the user or repo denied.
  """
  @spec apply_agent(t() | nil, map() | nil) :: t() | nil
  def apply_agent(policy, nil), do: policy

  def apply_agent(%__MODULE__{} = policy, %CodingAgent.Core.Agent{} = agent) do
    apply_agent(policy, %{
      permission: agent.permission,
      tools: agent.tools,
      disallowed_tools: agent.disallowed_tools
    })
  end

  def apply_agent(%__MODULE__{} = policy, agent) when is_map(agent) do
    layer = agent_layer(agent)

    %__MODULE__{
      entries: merge_layers([%{"__entries" => policy.entries}, layer]),
      enabled: narrow_enabled(enabled(policy), agent),
      disabled: (policy.disabled ++ agent_disabled(agent)) |> Enum.uniq() |> Enum.sort(),
      # a definition asking for a read-only shell root narrows the policy's;
      # it can never widen a `:ro` back to `:rw` (most-restrictive wins)
      shell_mode: merge_shell_mode([%{"__shell_mode" => policy.shell_mode}, layer])
    }
  end

  def apply_agent(policy, _agent), do: policy

  # A definition's `permission` table, in the same shape as a policy layer
  # (`shell = "read_only"` included), so the two merge identically.
  defp agent_layer(agent) do
    raw = agent[:permission] || agent["permission"] || %{}
    {raw, shell_mode} = split_shell_mode(raw, "agent definition")

    entries =
      Map.new(raw, fn {tool, rules} ->
        tool = CodingAgent.Core.Agent.canonical_tool(to_string(tool))
        {tool, normalize_agent_rules(rules)}
      end)

    %{"__entries" => entries, "__enabled" => agent_enabled(agent), "__shell_mode" => shell_mode}
  end

  # A definition's permission entry is either a bare decision string or a
  # glob table. Both map onto our entries shape; unknown decisions are
  # rejected at load (Agent.validate/2), so here we only accept the three.
  defp normalize_agent_rules(decision) when decision in ["allow", "ask", "deny"],
    do: %{"*" => String.to_existing_atom(decision)}

  defp normalize_agent_rules(rules) when is_map(rules) do
    Map.new(rules, fn {pattern, decision} ->
      {to_string(pattern), String.to_existing_atom(decision)}
    end)
  end

  defp normalize_agent_rules(_), do: %{}

  # The definition's tool set: `tools` is an allow-list, `disallowedTools`
  # a deny-list applied first (Claude Code semantics).
  defp agent_enabled(agent) do
    tools = agent[:tools] || agent["tools"]

    if is_list(tools) do
      tools |> Enum.map(&CodingAgent.Core.Agent.canonical_tool/1) |> Enum.uniq()
    else
      []
    end
  end

  defp agent_disabled(agent) do
    (agent[:disallowed_tools] || agent["disallowed_tools"] || [])
    |> Enum.map(&CodingAgent.Core.Agent.canonical_tool/1)
  end

  # Intersection, never union: a definition narrows, it does not extend.
  # Stored back as a list (`[]` means "no narrowing" and reads as
  # `:default` via enabled/1).
  defp narrow_enabled(existing, agent) do
    case agent_enabled(agent) -- agent_disabled(agent) do
      [] -> existing
      names -> intersect_enabled(existing, names)
    end
    |> store_enabled()
  end

  defp store_enabled(:default), do: []
  defp store_enabled(list), do: list

  defp intersect_enabled(:default, names), do: names
  defp intersect_enabled(existing, names), do: Enum.filter(existing, &(&1 in names))

  @doc "Loads one layer from a TOML file; nil or missing file => empty layer."
  @spec load_layer(String.t() | nil) :: layer()
  def load_layer(nil), do: %{}

  def load_layer(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_layer(content, path)

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        raise ArgumentError,
              "cannot read policy file #{Path.expand(path)}: #{:file.format_error(reason)}"
    end
  end

  defp parse_layer(content, path) do
    case Toml.decode(content, keys: :strings) do
      {:ok, doc} ->
        validate_layer(doc, path)

      {:error, reason} ->
        raise ArgumentError, "invalid TOML in #{path}: #{format_toml_error(reason)}"
    end
  end

  defp format_toml_error(%Toml.Error{} = e), do: Exception.message(e)

  defp format_toml_error(other) when is_tuple(other) and is_binary(elem(other, 1)) do
    case other do
      {tag, message} when tag in [:invalid_toml, :invalid] -> to_string(message)
      _ -> inspect(other)
    end
  end

  defp format_toml_error(other), do: inspect(other)

  defp validate_layer(doc, path) when is_map(doc) do
    unless Map.has_key?(doc, "permissions") or Map.has_key?(doc, "tools") do
      # A file with neither section is legal but suspicious; treat as empty.
      IO.warn("policy file #{path} has no [permissions] and no [tools] section")
    end

    perms = Map.get(doc, "permissions", %{})

    unless is_map(perms) do
      raise ArgumentError, "invalid policy #{path}: [permissions] must be a table"
    end

    enabled = validate_enabled(doc, path)
    {perms, shell_mode} = split_shell_mode(perms, path)

    entries =
      Map.new(perms, fn {tool, patterns} -> {tool, validate_entries(tool, patterns, path)} end)

    %{"__entries" => entries, "__enabled" => enabled, "__shell_mode" => shell_mode}
  end

  defp validate_layer(other, path) do
    raise ArgumentError, "invalid policy #{path}: expected a table, got #{inspect(other)}"
  end

  # `shell = "read_only"` is a bare value on the shell key, not a decision:
  # it means "allowed, but the sandbox binds the scope root read-only".
  # It is the ONLY key that accepts it (only shell has a rw/ro root).
  # Pulled out here so the rest of the table stays pattern => decision.
  defp split_shell_mode(perms, path) do
    validate_read_only_keys(perms, path)

    case Map.get(perms, "shell") do
      "read_only" ->
        # `read_only` means "allowed, but confined to a read-only root" —
        # an explicit allow entry plus the mode. If it could not be honoured
        # (no confining sandbox) the shell tool REFUSES at execution rather
        # than silently running read-write.
        {Map.put(perms, "shell", %{"*" => "allow"}), :ro}

      _other ->
        {perms, :rw}
    end
  end

  defp validate_read_only_keys(perms, path) do
    Enum.each(perms, fn
      {"shell", _} ->
        :ok

      {_tool, "read_only"} ->
        raise ArgumentError,
              "invalid policy #{path}: `read_only` is only valid on the shell key " <>
                "(no other tool has a read-write/read-only root)"

      _ ->
        :ok
    end)
  end

  defp validate_enabled(doc, path) do
    case Map.get(doc, "tools") do
      nil ->
        []

      %{"enabled" => list} when is_list(list) ->
        Enum.map(list, &to_string/1)

      other ->
        raise ArgumentError,
              "invalid policy #{path}: [tools] enabled must be an array, got: #{inspect(other)}"
    end
  end

  defp validate_entries(tool, patterns, path) do
    Map.new(patterns, fn {pattern, decision} ->
      case decision_for(decision) do
        {:ok, d} ->
          {pattern, d}

        :error ->
          raise ArgumentError,
                "invalid policy #{path}: permissions.#{tool}.#{inspect(pattern)} = " <>
                  "#{inspect(decision)} (must be \"allow\", \"ask\" or \"deny\")"
      end
    end)
  end

  defp decision_for(d) when d in @decisions, do: {:ok, String.to_existing_atom(d)}
  defp decision_for(_), do: :error

  # -- Merging (most restrictive wins) -------------------------------------------

  defp merge_layers(layers) do
    Enum.reduce(layers, %{}, fn layer, acc ->
      entries = Map.get(layer, "__entries", %{})

      Map.merge(acc, entries, fn _tool, a, b -> merge_entries(a, b) end)
    end)
  end

  defp merge_entries(a, b) do
    Map.merge(a, b, fn _pattern, d1, d2 -> most_restrictive(d1, d2) end)
  end

  @doc "The most restrictive of two decisions (deny > ask > allow)."
  @spec most_restrictive(decision(), decision()) :: decision()
  def most_restrictive(d1, d2) do
    if rank(d1) >= rank(d2), do: d1, else: d2
  end

  defp rank(:allow), do: 0
  defp rank(:ask), do: 1
  defp rank(:deny), do: 2

  # The shell root mode merges restrictively like a decision: any layer
  # asking for `:ro` wins, because read-write is the wider grant. A layer
  # silent on it (`:rw` default) never widens a `:ro` from another layer.
  defp merge_shell_mode(layers) do
    if Enum.any?(layers, &(Map.get(&1, "__shell_mode", :rw) == :ro)), do: :ro, else: :rw
  end

  # Enablement merges by INTERSECTION, not union: a layer may only
  # narrow the enabled set, never widen it. Union would let a project
  # file re-enable a tool the user disabled — an elevation, which the
  # non-elevation rule forbids (ADR 010 §2). A layer with no [tools]
  # enabled section ([] here) imposes no restriction and is skipped;
  # all layers silent => [] => `enabled/1` returns :default.
  defp enabled_tools(layers) do
    layers
    |> Enum.map(&Map.get(&1, "__enabled", []))
    |> Enum.reject(&(&1 == []))
    |> case do
      [] ->
        []

      lists ->
        [first | rest] = Enum.map(lists, &MapSet.new/1)

        rest
        |> Enum.reduce(first, &MapSet.intersection/2)
        |> MapSet.to_list()
        |> Enum.sort()
    end
  end

  # -- Lookup ----------------------------------------------------------------------

  @doc """
  Effective decision for `tool` on `rel_path` (relative to the scope
  root). This is THE production policy path: an explicit entry always
  wins, otherwise the fallback applies.

  The fourth argument is either a keyword list with `:fallback` (the
  gate supplies its confinement-aware fallback, ADR 015) or the legacy
  `role` string, which is ignored — the parameter was never used and is
  kept only so existing callers/tests keep compiling.
  """
  @spec effective(t(), String.t(), String.t() | nil, keyword() | String.t()) :: decision()
  def effective(policy, tool, rel_path, opts_or_role \\ [])

  def effective(policy, tool, rel_path, role) when is_binary(role),
    do: effective(policy, tool, rel_path, [])

  def effective(policy, tool, rel_path, opts) when is_list(opts) do
    case matching_entry(policy, tool, rel_path) do
      {:ok, decision} -> decision
      :no_match -> Keyword.get(opts, :fallback, default_for(tool))
    end
  end

  @doc "Built-in class default when no entry matches."
  @spec default_for(String.t()) :: decision()
  def default_for(tool) do
    if tool in @allow_class, do: :allow, else: :ask
  end

  # The explicit-entry lookup for effective/4: an explicit entry always
  # wins over the fallback, including an explicit `ask`/`deny` the gate
  # must never let confinement override (ADR 015).
  defp matching_entry(policy, tool, rel_path) do
    policy.entries
    |> Map.get(tool, %{})
    |> Enum.flat_map(fn {pattern, decision} ->
      if glob_match?(pattern, rel_path), do: [{pattern, decision, specificity(pattern)}], else: []
    end)
    |> case do
      [] ->
        :no_match

      matching ->
        {_, decision, _} = Enum.max_by(matching, fn {_, d, s} -> {s, rank(d)} end)
        {:ok, decision}
    end
  end

  defp specificity(pattern), do: pattern |> String.split("/") |> length()

  # -- Glob matching ---------------------------------------------------------------
  # ONE matcher (Core.GlobMatch), shared with the glob tool so a policy
  # pattern and a search pattern cannot drift. The old local builder made
  # "**" unable to match zero directories, so "docs/**/*.ex" silently
  # missed files directly under docs/.

  defp glob_match?(pattern, path), do: GlobMatch.match?(pattern, path)

  # -- Tool list ------------------------------------------------------------------

  @doc """
  Tools enabled for this policy. An empty `[tools] enabled` section in
  every layer means `:default` — the whole registry (`Tools.all/1`); a
  non-empty list is a whitelist the session narrows the registry to.
  Layers merge by intersection, so a project layer can only disable
  more, never re-enable what a user layer disabled.
  """
  @spec enabled(t()) :: [String.t()] | :default
  def enabled(%__MODULE__{enabled: []}), do: :default
  def enabled(%__MODULE__{enabled: list}), do: list

  @doc """
  Tools removed by an agent's `disallowedTools` (ADR 017). Applied after
  `enabled/1`: the session drops these names from the registry, so the
  model cannot even see them.
  """
  @spec disabled(t()) :: [String.t()]
  def disabled(%__MODULE__{disabled: list}), do: list

  @doc """
  How read-write `shell` is for this policy: `:rw` (the scope root is
  writable) or `:ro` (allowed, but the sandbox binds the root read-only).
  """
  @spec shell_mode(t()) :: shell_mode()
  def shell_mode(%__MODULE__{shell_mode: mode}), do: mode
end
