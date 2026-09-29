defmodule CodingAgent.Core.External do
  @moduledoc """
  External search binaries (ADR 016): `rg` (ripgrep) for the `grep` tool
  and `fd` for the `glob` tool.

  These are **runtime** binaries, not Elixir dependencies. Since ADR 030
  they are **REQUIRED**: the read tools delegate to them, and when a
  binary is absent the tool refuses with a clear error naming the
  dependency. There is no pure-Elixir fallback — the BEAM walk that used
  to run was a second, unconfined boundary (it ignored `hide`/`ro`/
  `root_ro`). This keeps ADR 002's "no NIF, no Node, no build-time
  dependency" intact: nothing is required to compile or ship, only to
  search.

  Probes are memoised per OS process. The `rg` probe also requires the
  `pcre2` feature: the tool's patterns come from Elixir's `Regex`
  (PCRE), so a ripgrep built with only the Rust regex engine could
  reject or reinterpret a valid pattern — that is why the probe checks
  the feature, not just the binary.

  The probe result can be forced for tests with `put/2` / cleared with
  `reset/0`.
  """

  @type tool :: :rg | :fd

  @doc """
  Probes for `tool`: `{:ok, path}` when usable, `:error` otherwise.
  Memoised; use `put/2` in tests to force a result.
  """
  @spec probe(tool()) :: {:ok, String.t()} | :error
  def probe(tool) when tool in [:rg, :fd] do
    key = {__MODULE__, tool}

    case :persistent_term.get(key, :unset) do
      :unset ->
        result = do_probe(tool)
        :persistent_term.put(key, result)
        result

      result ->
        result
    end
  end

  @doc "Forces a probe result (tests): `:ok`-path or `:error`."
  @spec put(tool(), {:ok, String.t()} | :error) :: :ok
  def put(tool, result) when tool in [:rg, :fd] do
    :persistent_term.put({__MODULE__, tool}, result)
    :ok
  end

  @doc "Clears memoised probes so the next call re-probes."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase({__MODULE__, :rg})
    :persistent_term.erase({__MODULE__, :fd})
    :ok
  end

  @doc "Convenience: whether `tool` is usable."
  @spec available?(tool()) :: boolean()
  def available?(tool), do: match?({:ok, _}, probe(tool))

  defp do_probe(:rg) do
    with path when is_binary(path) <- System.find_executable("rg"),
         true <- rg_has_pcre2?(path) do
      {:ok, path}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp do_probe(:fd) do
    case System.find_executable("fd") do
      nil -> :error
      path -> {:ok, path}
    end
  rescue
    _ -> :error
  end

  # `rg --version` prints a `features:+pcre2` line. Parsing it is cheaper
  # and more reliable than compiling a PCRE-only pattern.
  defp rg_has_pcre2?(path) do
    case System.cmd(path, ["--version"], stderr_to_stdout: true) do
      {out, 0} -> out =~ "features:" and out =~ "+pcre2"
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  The shared skip-dir names (Containment's list), for building the
  external tools' exclude arguments so both engines skip the same trees.
  """
  @spec skip_dirs() :: [String.t()]
  def skip_dirs, do: CodingAgent.Core.Containment.default_skip_dirs() |> MapSet.to_list()

  @doc """
  The `fd`/`rg` exclude arguments for the shared skip list (ADR 016).

  A bare ``--exclude <name>`` also prunes a FILE of that name (measured:
  a file called ``cover`` disappeared); ``**/<dir>/**`` prunes the
  directory subtree at any depth and leaves same-named files alone. ONE
  builder so ``glob`` and the ``@``-picker cannot drift.
  """
  @spec exclude_args() :: [String.t()]
  def exclude_args do
    Enum.flat_map(skip_dirs(), fn dir -> ["--exclude", "**/#{dir}/**"] end)
  end
end
