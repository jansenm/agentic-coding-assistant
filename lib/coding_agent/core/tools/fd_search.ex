defmodule CodingAgent.Core.Tools.FdSearch do
  @moduledoc """
  The confined `fd` invocation shared by `glob` and the `@`-file picker
  (ADR 016/030/032).

  ADR 030 made `fd` the only filename enumerator: it runs as a child
  process through `Core.Exec` under the scope's sandbox profile, so a
  `hide`/`ro` grant holds and there is no BEAM walk. This module owns the
  two halves both callers need — running `fd` and parsing its output into
  scope-relative, in-scope, sorted paths — so `glob` and the picker
  cannot drift on the flags, the profile, or the physical re-check.

  A caller supplies the `fd` ARGUMENTS (its own pattern/flag set) and
  filters the returned paths with its own rule; the parsing here is the
  common floor.
  """

  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.External
  alias CodingAgent.Core.Tools

  # fd runs through the one executor (Exec + Sandbox).
  @exec_timeout 60

  @doc """
  Probes for `fd` and runs it with `args` under `scope`'s profile,
  returning `{:ok, stdout}` on exit 0.

  Errors are explicit, never a fallback: a missing `fd` is
  `{:error, :fd_unavailable}` (ADR 030 made the binary required); a
  non-zero exit is `{:error, {:fd_failed, output}}` (fd reports "no
  matches" with exit 0, so any non-zero is a real failure whose text must
  not reach the model as a result).
  """
  @spec run(Tools.scope(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def run(scope, args) do
    case External.probe(:fd) do
      {:ok, fd} ->
        root = Path.expand(scope.root)
        profile = scope |> Tools.profile() |> Map.put(:root, root)

        # truncate: false — fd's output is parsed as PATHS, and the
        # truncation banner is prose that `parse_paths/2` would otherwise
        # keep as a phantom match (review F2/F5). A machine consumer must
        # see the raw list.
        case Exec.run({:exec, fd, args}, root, @exec_timeout, profile, truncate: false) do
          {:ok, out, 0} -> {:ok, out}
          {:ok, out, _} -> {:error, {:fd_failed, out}}
          {:timeout, out} -> {:error, {:fd_timeout, out}}
          {:stopped, out} -> {:error, {:fd_stopped, out}}
          {:raw_too_large, size} -> {:error, {:fd_too_large, size}}
          {:error, reason} -> {:error, reason}
          {:sandbox_error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :fd_unavailable}
    end
  end

  @doc "The user-facing message for a `run/2` error."
  @spec error_message(term()) :: String.t()
  def error_message(:fd_unavailable),
    do:
      "fd is required for filename search and was not found on PATH; " <>
        "install fd-find to enable it"

  def error_message({:fd_failed, _out}),
    do: "fd failed to complete the search; check the pattern"

  def error_message({:fd_timeout, _out}),
    do: "fd did not finish within the search timeout; narrow the search"

  def error_message({:fd_stopped, _out}),
    do: "fd search stopped by the user"

  def error_message({:fd_too_large, _out}),
    do: "fd produced more output than can be held in memory; narrow the pattern"

  def error_message(reason), do: "fd failed: #{inspect(reason)}"

  # The `fd` result filter: parse the printed paths, keep the ones
  # physically inside the scope (a symlink out can never be listed), and
  # return them relative to the root, sorted. Hidden filtering is the
  # CALLER's rule (naming is the opt-in), so it is not applied here.
  @doc """
  Parses `fd` output into scope-relative, in-scope paths, sorted. `fd`
  may print absolute or `./`-prefixed paths; both are normalized.

  A line that is not a path at all is dropped, not reported: the
  truncation banner (should it ever reach here — a non-picker consumer
  that forgot `truncate: false`) and `[fd error]` diagnostics are prose,
  and returning them would put a phantom "file" into the result (review
  F2/F5). A blank line is skipped by `trim: true`.
  """
  @spec parse_paths(String.t(), String.t()) :: [String.t()]
  def parse_paths(out, root) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reject(&not_a_path?/1)
    |> Enum.map(&Path.expand(&1, root))
    |> Enum.filter(&Tools.in_scope?(%{root: root}, &1))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  # The one shape a line must NOT have to be treated as a path: the
  # truncation marker (`[... output truncated...`) or an fd diagnostic
  # (`[fd error] ...`). A real path may start with `[` and contain `]` —
  # `[a]needle.ex` is a legal filename — so the match is on the exact
  # banner prefixes, not "looks bracketed".
  defp not_a_path?(line) do
    line = String.trim_leading(line)
    String.starts_with?(line, ["[...", "[fd "])
  end
end
