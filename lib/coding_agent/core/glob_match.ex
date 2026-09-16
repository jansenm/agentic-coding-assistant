defmodule CodingAgent.Core.GlobMatch do
  @moduledoc """
  The ONE glob matcher (ADR: a single dialect). Both the permission
  layer (`Permissions.effective/4`) and the `glob` tool match paths
  through this module, so a policy pattern and a search pattern agree.

  Dialect: `*` matches within one path segment, `?` matches one
  character inside a segment, `**` spans ZERO or more whole segments.
  Everything else is literal.

  ## Why this module exists

  There used to be two implementations. `Glob` built its regex by
  consuming the segment list, so `**` could absorb the following slash
  and match zero directories (`lib/**/*.ex` matched `lib/a.ex`).
  `Permissions` joined per-segment regexes with `/`, so `**` became
  `(?:.*)` wedged between slashes and could NOT match the zero-directory
  case (`docs/**/*.ex` did not match `docs/a.ex`) — despite the
  moduledoc promising "same dialect as the permission layer"
  (codereview §10). A user writing `"docs/**/*.ex" = "deny"` got a
  silent hole for files directly in `docs/`.

  Braces (`{a,b}`) are NOT part of this dialect; `Glob` expands them
  before calling in (a search-time convenience the policy loader does
  not offer, keeping policy patterns unambiguous).
  """

  @doc """
  True when `path` matches the glob `pattern` with `**` spanning zero
  or more segments.
  """
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(pattern, path) do
    Regex.match?(regex(pattern), path)
  end

  @doc "Compiles a glob to an anchored regex (public for tests)."
  @spec regex(String.t()) :: Regex.t()
  def regex(pattern) do
    segments = String.split(pattern, "/", trim: false)
    Regex.compile!("^" <> build(segments) <> "$")
  end

  # A lone "**" matches anything (zero or more segments).
  defp build(["**"]), do: "(?:.*)?"

  # "**" before more segments: either nothing, or one-or-more whole
  # directories then the rest. The alternation is what lets
  # "lib/**/*.ex" match "lib/a.ex" (zero dirs) AND "lib/x/a.ex".
  defp build(["**" | rest]) do
    inner = build(rest)
    "(?:" <> inner <> "|" <> "(?:[^/]+/)+" <> inner <> ")"
  end

  defp build([seg | rest]) do
    tail = if(rest == [], do: "", else: "/" <> build(rest))
    segment_regex(seg) <> tail
  end

  defp build([]), do: ""

  defp segment_regex(seg) do
    seg
    |> Regex.escape()
    |> String.replace("\\*", "[^/]*")
    |> String.replace("\\?", "[^/]")
  end
end
