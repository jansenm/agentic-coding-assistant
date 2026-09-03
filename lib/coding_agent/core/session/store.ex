defmodule CodingAgent.Core.Session.Store do
  @moduledoc """
  Session persistence (slice 4a): save and resume conversations.

  ADR 003 made the session state plain data precisely so this slice
  could exist: persisting is writing the state, resuming is reading it
  back — not an exception path.

  Format: a version-tagged `:erlang.term_to_binary` wrapper.

  - exact round-trip of the full state (context messages with their
    structs, policy, pending calls) with zero custom encoders;
  - the version byte makes old formats detectable: a mismatched or
    corrupt file fails **closed** (returns an error, never a half
    state) — same discipline as the permission loader.

  Storage: one file per session under the user state dir
  (`XDG_STATE_HOME` or `~/.local/state/coding_agent/sessions/`).
  Nothing in the repo; sessions are user-local artifacts.
  """

  alias CodingAgent.Core.Session.State

  @format_version 1

  @doc "Directory where session files live (created on demand)."
  @spec dir() :: String.t()
  def dir do
    base =
      System.get_env("XDG_STATE_HOME") ||
        Path.join(System.user_home!(), ".local/state")

    Path.join([base, "coding_agent", "sessions"])
  end

  @doc "File path for a session id."
  @spec path(String.t()) :: String.t()
  def path(id), do: Path.join(dir(), "#{id}.session")

  @doc """
  Persists the session state atomically (tmp file + rename). Returns
  :ok or {:error, reason} — persistence failure never crashes the
  session; the in-memory session stays usable.
  """
  @spec save(CodingAgent.Core.Session.State.t()) :: :ok | {:error, term()}
  def save(%CodingAgent.Core.Session.State{} = state) do
    payload = :erlang.term_to_binary({@format_version, state})

    with :ok <- File.mkdir_p(dir()),
         tmp = Path.join(dir(), ".tmp-#{System.unique_integer()}"),
         :ok <- File.write(tmp, payload),
         :ok <- File.rename(tmp, path(state.id)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Loads a persisted session. Fail-closed: anything unexpected —
  missing file, corrupt bytes, wrong version, wrong module — is an
  error tuple, never a half-restored state.
  """
  @spec load(String.t()) :: {:ok, CodingAgent.Core.Session.State.t()} | {:error, term()}
  def load(id) do
    file = path(id)

    case File.read(file) do
      {:ok, bytes} ->
        case safe_binary_to_term(bytes) do
          {:ok, {@format_version, %State{} = state}} ->
            # runtime-only fields must not resurrect
            {:ok, %State{state | subscribers: [], status: idle_or_interrupted(state)}}

          {:ok, other} ->
            # wrong version or foreign payload — same fail-closed verdict
            {:error, {:not_a_session_file, elem(other, 0)}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Deletes a persisted session (best effort)."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    _ = File.rm(path(id))
    :ok
  end

  @doc "Lists persisted sessions, newest first: [{id, saved_at, model}]."
  @spec list() :: [
          %{id: String.t(), saved_at: DateTime.t(), model: String.t() | nil, status: atom()}
        ]
  def list do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".session"))
        |> Enum.map(fn file ->
          id = Path.basename(file, ".session")
          path = Path.join(dir(), file)

          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime}} ->
              with {:ok, state} <- load(id) do
                %{
                  id: id,
                  saved_at: DateTime.from_unix!(mtime),
                  model: state.model,
                  status: state.status
                }
              end

            {:error, _} ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.saved_at, {:desc, DateTime})

      {:error, _} ->
        []
    end
  end

  # Corrupt bytes must error, never crash (rescue). Note on [:safe]:
  # binary_to_term with [:safe] rejects atoms that don't already exist
  # in the running VM — a saved session legitimately contains provider
  # atoms from the model's turn (option keys, error tags) that a NEW
  # VM hasn't created, so [:safe] breaks resume (found live in 4a).
  # Sessions are user-local files (~/.local/state, same trust domain
  # as .env/.bashrc); untrusted-input hardening is not the threat model
  # here. We keep the rescue for corruption, drop [:safe] for atoms.
  defp safe_binary_to_term(bytes) do
    {:ok, :erlang.binary_to_term(bytes)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # A saved :running/:interrupted session resumes as paused work, not a
  # running process pretending to stream.
  defp idle_or_interrupted(%{status: s}) when s in [:running, :error], do: :idle
  defp idle_or_interrupted(%{status: s}), do: s
end
