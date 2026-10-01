defmodule CodingAgent.Core.ProjectMemory do
  @moduledoc """
  Project memory: the `AGENTS.md` long-term-memory tier (memory.rst).

  Knowledge written down as a file in the repository, pulled back into the
  system prompt at session start. The file lives in *your* project —
  versioned, greppable, edited with the same tools the agent uses — so the
  loader is small on purpose: no exotic memory system.

  Kept out of the session loop (P3 factoring): the session asks for the
  section and composes; the file I/O and its failure policy live here.

  ## Nested files (subdirectories)

  A session reads ONLY ``<scope_root>/AGENTS.md``. The scope root is the
  directory the session was started in — we do not walk up to a repo
  root; a session in a subdirectory reads that subdirectory's own file.

  The ``AGENTS.md`` convention also places files in subdirectories, and
  those apply when the agent works *there*. So the section TELLS the
  model that subdirectories below the scope root may carry their own
  ``AGENTS.md`` and to read them with ``read_file`` when it works there.
  Walking down to collect them instead would be unbounded (a monorepo
  can have hundreds, most irrelevant to the work at hand) and would
  invert the granularity: a package's file applies in the package, not
  at the scope root.

  Policy, unchanged from when this lived in `Session`:

    * a missing `AGENTS.md` is the normal case, not an error;
    * an oversized file is truncated to 64 KiB with a warning;
    * an unreadable file degrades to a warning and no section.
  """

  require Logger

  @agents_file "AGENTS.md"
  @max_bytes 64 * 1024

  @doc """
  Appends the project-memory section to `prompt`. A nil scope root, no
  readable file on the walk, or only unreadable files leave `prompt`
  unchanged.
  """
  @spec append(String.t(), String.t() | nil) :: String.t()
  def append(prompt, scope_root) do
    case load(scope_root) do
      nil -> prompt
      section -> prompt <> "\n\n" <> section
    end
  end

  @doc """
  The project-memory section for the scope root, or `nil` when there is no
  readable memory to add.
  """
  @spec load(String.t() | nil) :: String.t() | nil
  def load(scope_root) when is_binary(scope_root) do
    scope_root
    |> dirs()
    |> Enum.flat_map(&read/1)
    |> case do
      [] -> nil
      files -> section(files, Path.expand(scope_root))
    end
  end

  def load(_), do: nil

  # The directories to read: the scope root alone. The scope root is where
  # the session was started; a file in a parent (outside the scope) is not
  # ours to read.
  @doc false
  @spec dirs(String.t()) :: [String.t()]
  def dirs(scope_root), do: [Path.expand(scope_root)]

  # One readable AGENTS.md as `[{path, text}]`, or `[]` when absent /
  # unreadable / oversized beyond the cap.
  defp read(dir) do
    file = Path.join(dir, @agents_file)

    if File.regular?(file) do
      case File.read(file) do
        {:ok, bytes} when byte_size(bytes) <= @max_bytes ->
          [{file, bytes}]

        {:ok, bytes} ->
          Logger.warning("AGENTS.md larger than 64 KiB; truncated for the system prompt")
          [{file, binary_part(bytes, 0, @max_bytes)}]

        {:error, reason} ->
          Logger.warning("AGENTS.md unreadable: #{inspect(reason)}")
          []
      end
    else
      []
    end
  end

  # The section: an intro, one labelled sub-section per file (labelled by
  # its path relative to the git root, so the model sees the scope), and a
  # pointer to deeper files it must read itself.
  defp section(files, scope_root) do
    body =
      Enum.map_join(files, "\n\n", fn {path, text} ->
        "## #{label(path, scope_root)}\n\n#{String.trim_trailing(text)}"
      end)

    """
    # Project memory (AGENTS.md)

    Conventions and context for this project, written by the team.

    #{body}

    ## Deeper files

    Subdirectories below the working directory may have their own `AGENTS.md`.
    Read them with the `read_file` tool when you work there — they are not
    included above.
    """
  end

  # A file's label: its path relative to the scope root — always `AGENTS.md`,
  # since only that one file is read. Relative so no absolute host path is
  # leaked into the prompt.
  defp label(path, scope_root), do: Path.relative_to(path, scope_root)
end
