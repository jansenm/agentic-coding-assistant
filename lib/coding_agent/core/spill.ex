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

  @doc """
  Opens a streaming spill writer: the caller writes the output AS IT
  ARRIVES (``write/2``) instead of assembling the whole buffer in BEAM
  memory first. This is what bounds ``Exec``'s memory for an unbounded
  command (found live: a runaway ``shell`` grew the BEAM to 11 GB and
  four OOM kills froze the desktop).

  The file is the SAME shape ``spill/3`` produces: head up to
  ``@max_bytes - @tail_bytes``, then an in-file marker, then the last
  ``@tail_bytes`` (the tail is the most useful part of a crashed build's
  log, so it is kept). The tail is held in memory, bounded by
  ``@tail_bytes`` (1 MiB), and flushed by ``finish/1``; everything else
  is written as it arrives. Review N35: the first writer dropped the
  tail, so the two spill paths disagreed on the file's shape.

  ``scratch`` ``nil``/``""`` (no session) returns ``:no_scratch``: the
  caller keeps its plain in-memory truncation.
  """
  @spec open_writer(String.t() | nil, String.t()) ::
          {:ok, writer()} | :no_scratch | {:error, term()}
  def open_writer(scratch, label)

  def open_writer(scratch, _label) when not is_binary(scratch) or scratch == "",
    do: :no_scratch

  def open_writer(scratch, label) when is_binary(label) do
    dir = dir(scratch)

    with :ok <- File.mkdir_p(dir) do
      host = Path.join(dir, "#{label}-#{System.unique_integer([:positive, :monotonic])}")

      case File.open(host, [:write, :binary, :raw]) do
        {:ok, io} ->
          {:ok,
           %{
             io: io,
             host: host,
             scratch: scratch,
             written: 0,
             head_cap: @max_bytes - @tail_bytes,
             tail: [],
             tail_size: 0,
             capped?: false,
             path: nil
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @typedoc "A streaming spill writer (see `open_writer/2`)."
  @type writer :: %{
          io: File.io_device(),
          host: String.t(),
          scratch: String.t(),
          written: non_neg_integer(),
          head_cap: non_neg_integer(),
          tail: iodata(),
          tail_size: non_neg_integer(),
          capped?: boolean(),
          path: String.t() | nil
        }

  @doc """
  Writes `data` to the spill file. Head bytes go to the file as they
  arrive; once the head is full a marker is written and further bytes
  roll through a bounded in-memory tail. Returns ``{:ok, writer}`` while
  under the cap and ``{:capped, writer}`` at/after the cap.
  """
  @spec write(writer(), iodata()) :: {:ok, writer()} | {:capped, writer()}
  def write(%{capped?: true} = writer, data), do: {:capped, add_tail(writer, data)}

  def write(%{io: io, written: n, head_cap: cap} = writer, data) do
    size = IO.iodata_length(data)

    if n + size <= cap do
      IO.binwrite(io, data)
      {:ok, %{writer | written: n + size}}
    else
      space = max(cap - n, 0)
      bin = IO.iodata_to_binary(data)

      if space > 0 do
        IO.binwrite(io, binary_part(bin, 0, space))
      end

      IO.binwrite(io, "\n\n[... spill truncated at #{@max_bytes} bytes ...]\n")
      tail = binary_part(bin, space, byte_size(bin) - space)

      {:capped, %{writer | written: cap, capped?: true} |> add_tail(tail)}
    end
  end

  # The tail is kept as iodata and only COLLAPSED (to its last
  # `@tail_bytes`) once it exceeds twice that, so the per-chunk cost is
  # amortized (review N35's writer otherwise concatenated a 1 MiB tail on
  # every 64 KiB chunk — 16x write amplification in transient binaries).
  defp add_tail(%{tail: tail, tail_size: n} = writer, data) do
    n = n + IO.iodata_length(data)

    if n > 2 * @tail_bytes do
      bin = IO.iodata_to_binary([tail | data])
      keep = min(byte_size(bin), @tail_bytes)
      %{writer | tail: [binary_part(bin, byte_size(bin) - keep, keep)], tail_size: keep}
    else
      %{writer | tail: [tail | data], tail_size: n}
    end
  end

  @doc """
  Closes the writer and returns ``{:ok, writer}`` with the sandbox path
  filled in (the path the model is told to read). Idempotent: a writer
  already closed (``path`` set) is returned unchanged.
  """
  @spec finish(writer()) :: {:ok, writer()}
  def finish(%{path: path} = writer) when is_binary(path), do: {:ok, writer}

  def finish(%{io: io, host: host, scratch: scratch, tail: tail, tail_size: n} = writer) do
    # the rolling tail is flushed last, after the marker, so the file
    # keeps the same head + tail shape as `spill/3`
    if n > 0, do: IO.binwrite(io, tail)
    File.close(io)
    {:ok, %{writer | path: sandbox_path(host, scratch), tail: [], tail_size: 0}}
  end

  @doc "The host path of a spill writer (for reading the full output back)."
  @spec host_path(writer()) :: String.t()
  def host_path(%{host: host}), do: host

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
