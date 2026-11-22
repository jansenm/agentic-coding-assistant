# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Agent do
  @moduledoc """
  Agent definitions (ADR 017): user-authored presets discovered from
  Markdown + YAML frontmatter files, layered like every other
  configuration (ADR 014).

  A definition is `{name, description, prompt, mode, model, tools,
  permissions, scope}` — the data ADR 003 runs through the standard loop.
  This module owns **discovery, layering and validation**; the permission
  merge lives in `CodingAgent.Core.Permissions` (layer 4 of ADR 010).

  Locations, weakest to strongest:

    1. shipped (`priv/coding-agent/agents/*.md`)
    2. user (`~/.config/coding-agent/agents/*.md`)
    3. project (`<scope_root>/.coding-agent/agents/*.md`)

  A higher layer with the same name **replaces** the lower one. Within
  one layer a duplicate name is an error.

  **Loading fails closed, but aggregates.** Every file is parsed and
  validated; all problems (file, line, reason) are collected and
  returned together, so a user fixes them in one edit instead of five
  restarts (ADR 017 decision 2). A non-empty error list means no session
  starts.
  """

  alias CodingAgent.Core.Agent.Frontmatter

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          prompt: String.t(),
          mode: :primary | :subagent | :all | :internal,
          model: String.t() | nil,
          tools: [String.t()] | nil,
          disallowed_tools: [String.t()] | nil,
          permission: map(),
          temperature: number() | nil,
          max_turns: pos_integer() | nil,
          hidden: boolean(),
          source: String.t()
        }

  @enforce_keys [:name, :prompt, :source]
  defstruct name: nil,
            description: nil,
            prompt: "",
            mode: :all,
            model: nil,
            tools: nil,
            disallowed_tools: nil,
            permission: %{},
            temperature: nil,
            max_turns: nil,
            hidden: false,
            source: nil

  @modes ~w(primary subagent all internal)

  # Standard tool names (the agents convention: opencode/Claude Code) to
  # our canonical tool names. A definition written for another tool can
  # therefore name its tools the way that tool does.
  @tool_aliases %{
    "read" => "read_file",
    "list" => "list_dir",
    "write" => "write_file",
    "edit" => "edit",
    "delete" => "delete_file",
    "rm" => "delete_file",
    "move" => "move_file",
    "mv" => "move_file",
    "rename" => "move_file",
    "glob" => "glob",
    "grep" => "grep",
    "bash" => "shell",
    "webfetch" => "webfetch",
    "git" => "git",
    "task" => "task"
  }

  @doc "Maps a standard tool name to ours (unknown names pass through)."
  @spec canonical_tool(String.t()) :: String.t()
  def canonical_tool(name) when is_binary(name), do: Map.get(@tool_aliases, name, name)

  @doc "The tool-name aliases, for documentation and tests."
  def tool_aliases, do: @tool_aliases

  @doc """
  Whether the human may select this definition directly (ADR 029).

  True for ``:primary`` and ``:all``; false for ``:subagent``, which only
  another agent starts via the ``task`` tool; for ``:internal``, which the
  runtime drives (``compaction``); and for ``hidden`` definitions, which
  the @ menu (and Tab) must not offer. This is the ONE rule: the TUI's Tab
  cycle and the session's resume guard both read it, so the offering
  surface and the resume path cannot disagree.
  """
  @spec selectable?(t()) :: boolean()
  def selectable?(%__MODULE__{mode: mode, hidden: hidden}) do
    mode in [:primary, :all] and hidden != true
  end

  @doc """
  Whether another agent may start this definition through the ``task``
  tool (ADR 017/018).

  True for ``:subagent`` and ``:all`` — the mirror of ``selectable?/1``,
  which owns ``:primary``/``:all``. ``hidden`` is deliberately allowed
  here (ADR 029: that seam is exactly what it is for), and ``:internal``
  is not: the runtime drives those itself and never by delegation.
  """
  @spec delegatable?(t()) :: boolean()
  def delegatable?(%__MODULE__{mode: mode}) do
    mode in [:subagent, :all]
  end

  @doc """
  The one direct-selection resolver: the definition ``name`` refers to in
  ``definitions``, or ``{:error, reason}`` naming what the human may
  select instead.

  The mode rules live on the definition (``selectable?/1``); keeping the
  lookup here is what stops every start path from re-deriving
  ``Enum.find`` and its error shape. The session turns the definition
  into policy and prompt — that composition is not this function's job.
  """
  @spec resolve_selectable([t()], String.t()) :: {:ok, t()} | {:error, term()}
  def resolve_selectable(definitions, name) do
    case Enum.find(definitions, &(&1.name == name)) do
      nil -> {:error, {:unknown_agent, name, selectable_names(definitions)}}
      %__MODULE__{} = agent -> check_selectable(agent, definitions)
    end
  end

  defp check_selectable(%__MODULE__{} = agent, definitions) do
    if selectable?(agent) do
      {:ok, agent}
    else
      {:error, {:unselectable_agent, agent.name, agent.mode, selectable_names(definitions)}}
    end
  end

  # The names a direct selection may resolve to — the same list the TUI
  # offers, so an error names what IS available rather than the raw
  # definition set.
  defp selectable_names(definitions) do
    definitions |> Enum.filter(&selectable?/1) |> Enum.map(& &1.name)
  end

  # -- Loading -----------------------------------------------------------------

  @doc """
  Loads all agent definitions for a scope root, layered.

  Returns `{:ok, [t()]}` (sorted by name) or `{:error, [String.t()]}`
  with **every** problem found. Callers refuse to start on error.
  """
  @spec load(String.t() | nil) :: {:ok, [t()]} | {:error, [String.t()]}
  def load(scope_root \\ nil) do
    layers = [shipped_dir(), user_dir(), project_dir(scope_root)]

    {defs, errors} =
      Enum.reduce(layers, {%{}, []}, fn dir, {acc, errs} ->
        {found, layer_errs} = load_layer(dir)
        {Map.merge(acc, found), errs ++ layer_errs}
      end)

    if errors == [] do
      {:ok, defs |> Map.values() |> Enum.sort_by(& &1.name)}
    else
      {:error, errors}
    end
  end

  @doc """
  Loads a single layer directory: `{%{name => def}, errors}`. A missing
  directory is fine (no agents from this layer).
  """
  @spec load_layer(String.t() | nil) :: {%{String.t() => t()}, [String.t()]}
  def load_layer(nil), do: {%{}, []}

  def load_layer(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, [".md", ".markdown"]))
        |> Enum.sort()
        |> Enum.reduce({%{}, []}, fn file, {acc, errs} ->
          path = Path.join(dir, file)

          case parse_one(path) do
            {:ok, def} ->
              case Map.get(acc, def.name) do
                nil ->
                  {Map.put(acc, def.name, def), errs}

                existing ->
                  {acc,
                   errs ++
                     [
                       "#{path}: duplicate agent name #{inspect(def.name)} " <>
                         "(already defined by #{existing.source} in the same layer)"
                     ]}
              end

            {:error, err} ->
              {acc, errs ++ [err]}
          end
        end)

      {:error, :enoent} ->
        {%{}, []}

      {:error, reason} ->
        {%{}, ["#{dir}: #{:file.format_error(reason)}"]}
    end
  end

  defp parse_one(path) do
    with {:ok, fm} <- Frontmatter.parse_file(path),
         :ok <- validate(fm, path),
         {:ok, name} <- resolve_name(fm, path) do
      {:ok,
       %__MODULE__{
         name: name,
         description: fm.description,
         prompt: String.trim(fm.body),
         mode: mode(fm.mode),
         model: fm.model,
         tools: fm.tools,
         disallowed_tools: fm.disallowed_tools,
         permission: fm.permission,
         temperature: fm.temperature,
         max_turns: fm.max_turns,
         hidden: fm.hidden,
         source: path
       }}
    end
  end

  # -- Validation --------------------------------------------------------------

  @doc """
  Validates a parsed definition: description required, mode known,
  permission decisions in `allow | ask | deny`. Returns `:ok` or
  `{:error, message}`.
  """
  @spec validate(Frontmatter.t(), String.t()) :: :ok | {:error, String.t()}
  def validate(fm, path) do
    cond do
      blank?(fm.description) ->
        {:error, "#{path}: `description` is required (the delegation hint)"}

      fm.mode != nil and fm.mode not in @modes ->
        {:error,
         "#{path}: invalid `mode` #{inspect(fm.mode)} " <>
           "(must be one of #{Enum.join(@modes, ", ")})"}

      true ->
        validate_permission(fm.permission, path)
    end
  end

  defp validate_permission(perm, path) when is_map(perm) do
    Enum.reduce_while(perm, :ok, fn {tool, entries}, :ok ->
      case validate_entries(tool, entries) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, "#{path}: permission #{msg}"}}
      end
    end)
  end

  defp validate_permission(_other, path) do
    {:error, "#{path}: `permission` must be a mapping of tool -> decision"}
  end

  # `shell = "read_only"` is the one non-decision value: allowed, but the
  # scope root is bound read-only. It is shell-only (no other tool has a
  # read-write/read-only root), so anywhere else it is an error.
  defp validate_entries("shell", "read_only"), do: :ok

  defp validate_entries(_tool, "read_only") do
    {:error, "`read_only` is only valid on the shell key"}
  end

  defp validate_entries(_tool, decision) when decision in ["allow", "ask", "deny"], do: :ok

  defp validate_entries(_tool, entries) when is_map(entries) do
    Enum.reduce_while(entries, :ok, fn {pattern, decision}, :ok ->
      if decision in ["allow", "ask", "deny"] do
        {:cont, :ok}
      else
        {:halt,
         {:error, "#{inspect(pattern)} = #{inspect(decision)} (must be allow, ask or deny)"}}
      end
    end)
  end

  defp validate_entries(_tool, other) do
    {:error, "must be allow, ask or deny (or a glob table of those), got #{inspect(other)}"}
  end

  # name field wins; the file name (without extension) is the fallback.
  defp resolve_name(fm, path) do
    cond do
      is_binary(fm.name) and fm.name != "" ->
        {:ok, fm.name}

      true ->
        base = path |> Path.basename() |> Path.rootname()
        {:ok, base}
    end
  end

  defp mode(nil), do: :all
  defp mode("primary"), do: :primary
  defp mode("subagent"), do: :subagent
  defp mode("all"), do: :all
  defp mode("internal"), do: :internal
  defp mode(_), do: :all

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true

  # -- Paths -------------------------------------------------------------------

  @doc "Shipped agent definitions directory."
  def shipped_dir do
    Path.join([Application.app_dir(:coding_agent), "priv", "coding-agent", "agents"])
  end

  @doc "User agent definitions directory (~/.config/coding-agent/agents)."
  def user_dir do
    Path.join(CodingAgent.Core.UserConfig.global_dir(), "agents")
  end

  @doc "Project agent definitions directory (<scope_root>/.coding-agent/agents)."
  def project_dir(nil), do: nil

  def project_dir(scope_root) do
    Path.join(CodingAgent.Core.UserConfig.project_dir(scope_root), "agents")
  end
end
