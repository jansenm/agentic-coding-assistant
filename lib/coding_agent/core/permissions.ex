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
  """

  @typedoc "A policy decision."
  @type decision :: :allow | :ask | :deny

  @typedoc "Pattern => decision entries for one tool."
  @type entries :: %{String.t() => decision()}

  @typedoc "One policy layer: per-tool entries."
  @type layer :: %{String.t() => entries()}

  @typedoc "A complete policy: merged layers + enablement."
  @type t :: %__MODULE__{
          entries: %{String.t() => entries()},
          enabled: [String.t()]
        }

  @enforce_keys [:entries, :enabled]
  defstruct entries: %{}, enabled: []

  # Class defaults when no policy entry matches. Read-only tools
  # allow-by-policy (slice 2a); every addition must be safe by
  # construction and contained (see Containment): grep/glob joined in
  # 2d; `edit` joined by the 2026-09-15 ADR 010 amendment — contained
  # (physically-resolved paths), fail-closed (a stale or ambiguous
  # old_string refuses, the tool cannot guess) and reviewable (every
  # landed change sits in the VCS diff). write_file (whole-file
  # overwrite, no uniqueness check) and shell (no containment at all)
  # stay ask; webfetch stays ask.
  @allow_class ["list_dir", "read_file", "grep", "glob", "edit"]

  @decisions ~w(allow ask deny)

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
      enabled: enabled_tools([user_layer, repo_layer])
    }
  end

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

    entries =
      Map.new(perms, fn {tool, patterns} -> {tool, validate_entries(tool, patterns, path)} end)

    %{"__entries" => entries, "__enabled" => enabled}
  end

  defp validate_layer(other, path) do
    raise ArgumentError, "invalid policy #{path}: expected a table, got #{inspect(other)}"
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

  defp enabled_tools(layers) do
    layers |> Enum.flat_map(&Map.get(&1, "__enabled", [])) |> Enum.uniq()
  end

  # -- Lookup ----------------------------------------------------------------------

  @doc """
  Effective decision for `tool` on `rel_path` (relative to the scope
  root) running under `role`.
  """
  @spec effective(t(), String.t(), String.t() | nil, String.t()) :: decision()
  def effective(policy, tool, rel_path, _role \\ "default") do
    case matching_entry(policy, tool, rel_path) do
      {:ok, decision} -> decision
      :no_match -> default_for(tool)
    end
  end

  @doc "Built-in class default when no entry matches."
  @spec default_for(String.t()) :: decision()
  def default_for(tool) do
    if tool in @allow_class, do: :allow, else: :ask
  end

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

  defp glob_match?(pattern, path) do
    Regex.match?(glob_regex(pattern), path)
  end

  defp glob_regex(pattern) do
    pattern
    |> split_segments()
    |> Enum.map_join("/", &segment_regex/1)
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  defp split_segments(pattern), do: String.split(pattern, "/", trim: false)

  defp segment_regex("**"), do: "(?:.*)"

  defp segment_regex(segment) do
    segment
    |> escape_glob()
    |> String.replace("\\*", "[^/]*")
    |> String.replace("\\?", "[^/]")
  end

  # Escape regex metacharacters except the glob characters we translate.
  # Glob chars (* and ?) are escaped too, then re-translated above.
  defp escape_glob(segment) do
    segment
    |> String.replace("\\", "\\\\")
    |> String.replace("*", "\\*")
    |> String.replace("?", "\\?")
    |> String.replace("+", "\\+")
    |> String.replace(".", "\\.")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
    |> String.replace("{", "\\{")
    |> String.replace("}", "\\}")
    |> String.replace("^", "\\^")
    |> String.replace("$", "\\$")
    |> String.replace("|", "\\|")
  end

  # -- Tool list ------------------------------------------------------------------

  @doc """
  Tools enabled for this policy; an empty `[tools] enabled` section
  means "registry default" (all read-only tools).
  """
  @spec enabled(t()) :: [String.t()] | :default
  def enabled(%__MODULE__{enabled: []}), do: :default
  def enabled(%__MODULE__{enabled: list}), do: list
end
