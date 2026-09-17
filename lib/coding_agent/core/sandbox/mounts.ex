defmodule CodingAgent.Core.Sandbox.Mounts do
  @moduledoc """
  The user-configurable mount schema (ADR 015): which paths a confined
  process may write, read-only, or not see at all.

  Three directives, each a list of paths:

    * `rw`   — bind read-write (shared with the host)
    * `ro`   — bind read-only (readable, no write/delete)
    * `hide` — a directory becomes an empty tmpfs, a file becomes
      `/dev/null` (present but empty/unreadable)

  They live in `config.toml` under `[sandbox]`, and — like the
  permission layers — merge **non-elevating**: a layer may only tighten.
  Concretely:

    * `rw` is the sensitive directive: it *adds reach*. It may come only
      from the shipped defaults and the user layer, **never** from a
      project's `.coding-agent/config.toml`, so a checked-out repository
      cannot widen its own sandbox.
    * `ro` and `hide` may come from any layer (they only restrict).

  `resolve/1` takes the three config layers (shipped, global, project)
  and returns `%{rw: [...], ro: [...], hide: [...]}` with absolute,
  deduplicated paths.
  """

  @type t :: %{
          rw: [String.t()],
          ro: [String.t()],
          hide: [String.t()]
        }

  @doc """
  Resolves the effective mounts from the three config layers
  (weakest first, as returned by `UserConfig.layers/2`).

  `rw` is taken from shipped + global only (the elevation rule); `ro`
  and `hide` are unioned across all three.
  """
  @spec resolve([map()]) :: t()
  def resolve(layers) when is_list(layers) do
    shipped = Enum.at(layers, 0, %{})
    global = Enum.at(layers, 1, %{})
    project = Enum.at(layers, 2, %{})

    %{
      rw: dedup([shipped, global], :rw),
      ro: dedup([shipped, global, project], :ro),
      hide: dedup([shipped, global, project], :hide)
    }
  end

  @doc "The default mounts with no user configuration at all."
  @spec default() :: t()
  def default, do: resolve([%{}, %{}, %{}])

  @doc """
  Whether a path is eligible for a directive: it must be absolute or
  `~`-rooted (a relative path would resolve against a varying CWD, which
  is exactly the kind of surprise the schema must not have).
  """
  @spec eligible?(term()) :: boolean()
  def eligible?(path) when is_binary(path) and path != "" do
    String.starts_with?(path, "/") or String.starts_with?(path, "~")
  end

  def eligible?(_), do: false

  defp section(layer) do
    case Map.get(layer, "sandbox", %{}) do
      %{} = s -> s
      _ -> %{}
    end
  end

  defp entry(layer, key) do
    case Map.get(section(layer), key, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp dedup(layers, key) do
    key = to_string(key)

    layers
    |> Enum.flat_map(&entry(&1, key))
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&eligible?/1)
    |> Enum.map(&expand/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # `~`-rooted entries expand against HOME; `Path.expand/1` does this for
  # `~/…` but not for a bare `~`, which we normalise first.
  defp expand("~"), do: Path.expand(System.get_env("HOME") || "~")
  defp expand(path), do: Path.expand(path)
end
