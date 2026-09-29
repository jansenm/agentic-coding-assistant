defmodule CodingAgent.Core.Spill do
  @moduledoc """
  The tool-output spill store (ADR 038): when a tool would truncate its
  result, the overflow is written into the session scratch (ADR 022) so
  the model can retrieve it instead of losing it — and re-running the
  command to see the rest.

  One naming rule and one writer for every spill site (``Exec`` — shell
  and git —, ``grep``, ``webfetch``):

    * host file: ``<scratch>/spill/<label>-<n>``;
    * the path reported to the model: ``/tmp/spill/<label>-<n>`` — the
      same file as the sandbox sees it, because ADR 022 binds the scratch
      over ``/tmp``.

  A scope with no session id has no scratch: ``spill/3`` returns
  ``:no_scratch`` and the caller keeps its plain truncation. The feature
  degrades to "not available", never to "an unreadable path".
  """

  # A single spill is bounded: the scratch has no quota (ADR 022), so one
  # pathological command must not fill /tmp. Past this the file itself is
  # head+tail truncated, with an in-file marker — the same honest loss as
  # the tool truncation, one layer down.
  @max_bytes 16 * 1024 * 1024
  @tail_bytes 1 * 1024 * 1024

  @subdir "spill"

  @doc """
  Writes `content` to the session scratch and returns the path the model
  should read: ``{:ok, "/tmp/spill/<label>-<n>"}``.

  ``scratch`` is the host scratch directory (``Scratch.from_scope/1``);
  ``nil``/``""`` means no session scratch and the caller keeps its plain
  truncation (``:no_scratch``).
  """
  @spec spill(iodata(), String.t() | nil, String.t()) ::
          {:ok, String.t()} | :no_scratch | {:error, term()}
  def spill(content, scratch, label)

  def spill(_content, scratch, _label) when not is_binary(scratch) or scratch == "",
    do: :no_scratch

  def spill(content, scratch, label) when is_binary(label) do
    dir = dir(scratch)

    with :ok <- File.mkdir_p(dir) do
      host = Path.join(dir, "#{label}-#{System.unique_integer([:positive, :monotonic])}")

      case File.write(host, bound(content)) do
        :ok -> {:ok, sandbox_path(host, scratch)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The host spill directory inside a session scratch."
  @spec dir(String.t()) :: String.t()
  def dir(scratch), do: Path.join(scratch, @subdir)

  @doc """
  The sandbox-visible path for a host spill file: the scratch is bound at
  ``/tmp`` (ADR 022), so the host prefix is rewritten to ``/tmp``.
  """
  @spec sandbox_path(String.t(), String.t()) :: String.t()
  def sandbox_path(host_file, scratch) do
    "/tmp/" <> Path.relative_to(host_file, Path.expand(scratch))
  end

  @doc "The per-spill byte cap."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  defp bound(content) do
    data = IO.iodata_to_binary(content)

    if byte_size(data) <= @max_bytes do
      data
    else
      head = binary_part(data, 0, @max_bytes - @tail_bytes)
      tail = binary_part(data, byte_size(data) - @tail_bytes, @tail_bytes)

      head <>
        "\n\n[... spill truncated: #{byte_size(data)} bytes total; " <>
        "showing first #{byte_size(head)} and last #{@tail_bytes} ...]\n\n" <> tail
    end
  end
end
