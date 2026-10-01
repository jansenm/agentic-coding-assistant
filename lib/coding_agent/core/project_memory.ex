defmodule CodingAgent.Core.ProjectMemory do
  @moduledoc """
  Project memory: the `AGENTS.md` long-term-memory tier (memory.rst).

  Knowledge written down as a file in the repository, pulled back into the
  system prompt at session start. The file lives in *your* project —
  versioned, greppable, edited with the same tools the agent uses — so the
  loader is small on purpose: no exotic memory system.

  Kept out of the session loop (P3 factoring): the session asks for the
  section and composes; the file I/O and its failure policy live here.

  ## Nested files (monorepos)

  A session started in a subdirectory used to read only
  ``<scope_root>/AGENTS.md`` and lose the repo-root conventions. Now the
  loader walks UP from the scope root to the **git root** (the nearest
  ancestor with a ``.git`` entry; the scope root itself when it is the
  root, or when there is no git metadata) and concatenates every
  ``AGENTS.md`` on that path, **root first, scope last** — general to
  specific, so a more specific file is read as overriding the general one.

  It does NOT collect subdirectories below the scope root: a monorepo can
  have hundreds, most irrelevant to the work at hand, and reading them all
  is unbounded. The section instead TELLS the model that subdirectories
  may carry their own ``AGENTS.md`` and to read them with ``read_file``
  when it works there (opencode does the same: it walks up, not down).

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

  # The directories to read, git root -> scope root; the shared walk lives
  # in `Core.Repo` (also used by the sandbox and the config loader). A
  # non-repo scope yields `[scope_root]`, so it reads exactly the one file
  # it always did.
  @doc false
  @spec dirs(String.t()) :: [String.t()]
  def dirs(scope_root), do: CodingAgent.Core.Repo.dirs(scope_root)

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

    Conventions and context for this project, written by the team. Files are
    listed from the repository root down to the working directory; where
    they conflict, a more specific file (later) wins.

    #{body}

    ## Deeper files

    Subdirectories below the working directory may have their own `AGENTS.md`.
    Read them with the `read_file` tool when you work there — they are not
    included above.
    """
  end

  # A file's label: its path relative to the scope root. A file at the
  # scope root is `AGENTS.md`; an ancestor is `../../AGENTS.md`; no
  # absolute host path is leaked. Enough for the model to see where a rule
  # comes from.
  defp label(path, scope_root), do: Path.relative_to(path, scope_root)
end
