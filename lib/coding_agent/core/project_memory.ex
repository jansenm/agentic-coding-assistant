defmodule CodingAgent.Core.ProjectMemory do
  @moduledoc """
  Project memory: the `AGENTS.md` long-term-memory tier (memory.rst).

  Knowledge written down as a file in the repository, pulled back into the
  system prompt at session start. The file lives in *your* project —
  versioned, greppable, edited with the same tools the agent uses — so the
  loader is small on purpose: no exotic memory system.

  Kept out of the session loop (P3 factoring): the session asks for the
  section and composes; the file I/O and its failure policy live here.

  Policy, unchanged from when this lived in `Session`:

    * a missing `AGENTS.md` is the normal case, not an error;
    * an oversized file is truncated to 64 KiB with a warning;
    * an unreadable file degrades to a warning and no section.
  """

  require Logger

  @agents_file "AGENTS.md"
  @max_bytes 64 * 1024

  @doc """
  Appends the project-memory section to `prompt`. A nil scope root, a
  missing file, or an unreadable file leaves `prompt` unchanged.
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
  def load(scope_root) do
    file = scope_root && Path.join(scope_root, @agents_file)

    cond do
      not is_binary(file) -> nil
      not File.regular?(file) -> nil
      true -> read(file)
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, bytes} when byte_size(bytes) <= @max_bytes ->
        section(bytes)

      {:ok, bytes} ->
        Logger.warning("AGENTS.md larger than 64 KiB; truncated for the system prompt")
        section(binary_part(bytes, 0, @max_bytes))

      {:error, reason} ->
        Logger.warning("AGENTS.md unreadable: #{inspect(reason)}")
        nil
    end
  end

  defp section(text) do
    """
    # Project memory (AGENTS.md)

    Conventions and context for THIS project, written by the team:

    #{String.trim_trailing(text)}
    """
  end
end
