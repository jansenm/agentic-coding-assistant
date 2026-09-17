defmodule CodingAgent.Core.Agent.Frontmatter do
  @moduledoc """
  Parses Markdown files with YAML frontmatter (the agents standard, ADR
  017). The file name is the agent name; the Markdown body is the system
  prompt.

  Uses `yamerl` directly (ADR 019) with hard limits applied **here**, not
  in the parser:

    * a size cap on the frontmatter before parsing — an oversized
      definition is a load error, not a parse;
    * `str_node_as_binary: true` so scalars are binaries, never charlists;
    * the default **core schema only**. We never register
      `yamerl_node_erlang_fun` or `yamerl_node_erlang_atom`, so a
      definition can never execute code (`erl_eval`) or intern atoms.

  Returns `{:ok, %{name, description, body, mode, model, tools,
  disallowed_tools, permission, temperature, max_turns, hidden, raw}}`
  with keys as atoms, or `{:error, reason}` where reason is a
  human-readable string with a line number when the parser gives one.
  """

  @max_frontmatter_bytes 64 * 1024

  @type t :: %__MODULE__{
          name: String.t() | nil,
          description: String.t() | nil,
          body: String.t(),
          mode: String.t() | nil,
          model: String.t() | nil,
          tools: [String.t()] | nil,
          disallowed_tools: [String.t()] | nil,
          permission: map(),
          temperature: number() | nil,
          max_turns: pos_integer() | nil,
          hidden: boolean(),
          raw: map()
        }

  defstruct name: nil,
            description: nil,
            body: "",
            mode: nil,
            model: nil,
            tools: nil,
            disallowed_tools: nil,
            permission: %{},
            temperature: nil,
            max_turns: nil,
            hidden: false,
            raw: %{}

  @spec parse_file(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> parse(content, path)
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Parses file content. `source` is used only for error messages.
  """
  @spec parse(String.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(content, source \\ "<memory>") when is_binary(content) do
    case split(content) do
      {:ok, yaml, body} ->
        yaml
        |> parse_yaml(source)
        |> case do
          {:ok, map} -> {:ok, build(map, body)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, "#{source}: #{reason}"}
    end
  end

  # -- Splitting ---------------------------------------------------------------

  # Frontmatter is delimited by a leading `---` line and a closing `---`.
  # A file with no frontmatter is documentation, not an agent (Claude
  # Code's rule): an error here, so the aggregated loader reports it.
  defp split(content) do
    case String.split(content, ~r/\r?\n/) do
      ["---" | rest] -> split_at_close(rest, [])
      _ -> {:error, "no YAML frontmatter (the file must start with ---)"}
    end
  end

  defp split_at_close([], _acc), do: {:error, "frontmatter opened with --- but never closed"}

  defp split_at_close([line | rest], acc) do
    if line == "---" do
      body = Enum.join(rest, "\n")
      {:ok, acc |> Enum.reverse() |> Enum.join("\n"), body}
    else
      split_at_close(rest, [line | acc])
    end
  end

  # -- YAML --------------------------------------------------------------------

  defp parse_yaml(yaml, source) do
    if byte_size(yaml) > @max_frontmatter_bytes do
      {:error,
       "#{source}: frontmatter is #{byte_size(yaml)} bytes (max #{@max_frontmatter_bytes})"}
    else
      do_parse_yaml(yaml, source)
    end
  end

  defp do_parse_yaml(yaml, source) do
    :ok = ensure_yamerl_started()

    case :yamerl_constr.string(String.to_charlist(yaml), str_node_as_binary: true) do
      [doc] when is_list(doc) -> {:ok, proplist_to_map(doc)}
      [doc] when is_map(doc) -> {:ok, doc}
      [] -> {:ok, %{}}
      [_ | _] = docs -> {:error, "#{source}: expected one YAML document, got #{length(docs)}"}
      other -> {:error, "#{source}: unexpected YAML shape: #{inspect(other, limit: 3)}"}
    end
  catch
    {:yamerl_exception, [error | _]} ->
      {:error, "#{source}: #{format_yamerl_error(error)}"}

    kind, value ->
      {:error, "#{source}: YAML parse failed (#{inspect(kind)}: #{inspect(value, limit: 3)})"}
  end

  defp format_yamerl_error(error) do
    # yamerl errors are Erlang records; `inspect` shows the fields,
    # including the line/column and message. Good enough for a load
    # error a human reads and fixes.
    error |> inspect(limit: 8) |> String.replace(~r/\s+/, " ")
  end

  # yamerl returns proplists (lists of {key, value}) when not using
  # detailed_constr. Nested mappings are proplists too. Convert to maps;
  # duplicate keys keep the last (yamerl preserves them in order).
  defp proplist_to_map(list) when is_list(list) do
    Enum.reduce(list, %{}, fn
      {k, v}, acc when is_binary(k) -> Map.put(acc, k, convert(v))
      _other, acc -> acc
    end)
  end

  defp convert(value) when is_list(value) do
    if Enum.all?(value, &match?({k, _} when is_binary(k), &1)) do
      proplist_to_map(value)
    else
      Enum.map(value, &convert/1)
    end
  end

  defp convert(value), do: value

  # -- Building the definition -------------------------------------------------

  @known_strings ~w(name description mode model)

  defp build(map, body) do
    %__MODULE__{
      name: str(map["name"]),
      description: str(map["description"]),
      body: body,
      mode: str(map["mode"]),
      model: str(map["model"]),
      tools: str_list(map["tools"]),
      disallowed_tools: str_list(map["disallowedTools"] || map["disallowed_tools"]),
      permission: permission(map["permission"]),
      temperature: number(map["temperature"]),
      max_turns: pos_int(map["maxTurns"] || map["max_turns"]),
      hidden: map["hidden"] == true,
      raw: Map.take(map, @known_strings)
    }
  end

  defp str(v) when is_binary(v), do: String.trim(v)
  defp str(nil), do: nil
  defp str(_), do: nil

  # `tools: Read, Grep, Glob` (comma string) or a YAML list.
  defp str_list(v) when is_binary(v) do
    v
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp str_list(v) when is_list(v), do: Enum.filter(v, &is_binary/1)
  defp str_list(_), do: nil

  defp permission(v) when is_map(v), do: v
  defp permission(_), do: %{}

  defp number(v) when is_number(v), do: v
  defp number(_), do: nil

  defp pos_int(v) when is_integer(v) and v > 0, do: v
  defp pos_int(_), do: nil

  defp ensure_yamerl_started do
    case Application.ensure_all_started(:yamerl) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end
  end
end
