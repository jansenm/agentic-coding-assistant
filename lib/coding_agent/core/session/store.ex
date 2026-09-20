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

  alias CodingAgent.Core.Session.{Scratch, State}

  @format_version 1

  # Directory where session files live (created on demand). The path and
  # the :store_dir test override are decided in Core.Config (one reader);
  # this is just the typed accessor. The override exists so tests never
  # wipe the user's real session dir (this exact mistake deleted a live
  # session once; tests now isolate by default).
  @doc "Directory where session files live (created on demand)."
  @spec dir() :: String.t()
  def dir, do: CodingAgent.Core.Config.store_dir()

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
  Resolves a session id that may be a PREFIX (unique): "1730" matches
  "tui-1730..." when exactly one session does. Ambiguous and missing
  ids are errors — never guesses (fail-closed, like load/1).
  """
  @spec resolve_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_id(id) do
    case File.ls(dir()) do
      {:ok, files} ->
        # id matches exactly, or uniquely as a prefix or a suffix
        # ("1730" -> "tui-1730"): uniqueness required either way
        matching =
          files
          |> Enum.filter(fn f -> String.ends_with?(f, ".session") end)
          |> Enum.map(&Path.basename(&1, ".session"))
          |> Enum.filter(&(&1 == id or String.starts_with?(&1, id) or String.ends_with?(&1, id)))

        case matching do
          [found] -> {:ok, found}
          [] -> {:error, :enoent}
          many -> {:error, {:ambiguous_id, many}}
        end

      {:error, reason} ->
        {:error, reason}
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
            State.restore(state)

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

  # Snapshot healing lives in State.restore/1: the persistence FORMAT is
  # Store's concern, but the SHAPE of State and its nested structs is
  # not. Store decodes bytes and hands the state to State.

  @doc """
  Deletes a persisted session (best effort), including its session
  scratch directory (ADR 022).
  """
  @spec delete(String.t()) :: :ok
  def delete(id) do
    _ = File.rm(path(id))
    Scratch.remove(Scratch.path(id))
    :ok
  end

  @doc """
  Renames a persisted session: load, re-id, save under the new
  name, drop the old file. Intended for idle sessions — a live one
  keeps running under its old id and re-saves it on the next turn.
  Returns {:ok, new_id} or {:error, reason}.
  """
  def rename(id, new_id) when is_binary(new_id) do
    new_id = String.trim(new_id)

    cond do
      new_id == "" or new_id == id ->
        {:error, :invalid_name}

      # path-injection guard: new_id goes straight into path/1, so
      # "../x" would escape the sessions dir. The picker's
      # rename buffer accepts any printable char (including / and .), so
      # this is reachable interactively — keep the invariant explicit.
      not safe_id?(new_id) ->
        {:error, :invalid_name}

      File.exists?(path(new_id)) ->
        {:error, :exists}

      true ->
        case load(id) do
          {:ok, state} ->
            new_state = struct!(state, id: new_id)
            save(new_state)
            _ = File.rm(path(id))
            Scratch.move(Scratch.path(id), Scratch.path(new_id))
            # tell a live process under the old id (if any) so its next
            # save lands on the renamed file — the session layer owns the
            # registry lookup, not Store
            CodingAgent.Core.Session.notify_renamed(id, new_id)
            {:ok, new_id}

          err ->
            err
        end
    end
  end

  # A session id names exactly one file in the sessions dir: no path
  # separators, no "..", no leading dot (a name must not collide with
  # the hidden ".tmp-*" save files or traverse upward).
  @spec safe_id?(String.t()) :: boolean()
  defp safe_id?(id) do
    Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, id)
  end

  @doc """
  Lists persisted sessions, newest first. Each entry carries the
  storage footprint (`:size`, bytes — ADR 020 R13) and the persisted
  `:scope_root`, so a caller can show and group by project without
  decoding the state again.
  """
  @spec list() :: [
          %{
            id: String.t(),
            saved_at: DateTime.t(),
            model: String.t() | nil,
            status: atom(),
            scope_root: String.t() | nil,
            size: non_neg_integer()
          }
        ]
  def list do
    list_entries()
    |> Enum.map(&Map.take(&1, [:id, :saved_at, :model, :status, :scope_root, :size]))
  end

  @doc """
  Sessions for one working directory, newest first (the session
  picker: `mix tui` shows this when the cwd has previous sessions).
  Filters on the persisted scope_root.
  """
  @spec list_in(String.t()) :: [
          %{
            id: String.t(),
            saved_at: DateTime.t(),
            model: String.t() | nil,
            status: atom(),
            scope_root: String.t() | nil,
            size: non_neg_integer()
          }
        ]
  def list_in(root) do
    root = Path.expand(root)

    # ONE decode per file: scope_root is read off the same entry list/0
    # uses. list_in used to call list/0 (which loads every state) and
    # then load/1 each id AGAIN to filter — the second decode was pure
    # waste.
    list_entries()
    |> Enum.filter(&(&1.scope_root && Path.expand(&1.scope_root) == root))
    |> Enum.map(&Map.take(&1, [:id, :saved_at, :model, :status, :scope_root, :size]))
  end

  # Decode every session file ONCE: id, mtime, and the loaded state's
  # summary fields. list/0 and list_in/1 both derive from this pass.
  defp list_entries do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".session"))
        |> Enum.map(fn file ->
          id = Path.basename(file, ".session")
          path = Path.join(dir(), file)

          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime, size: size}} ->
              # a file can vanish or corrupt between ls and load; an
              # error tuple is NOT nil, so filter on the map shape — the
              # old `with`+reject(is_nil) let {:error, _} through and
              # sort_by crashed on it (BadMapError, found live under a
              # concurrent picker test)
              case load(id) do
                {:ok, state} ->
                  %{
                    id: id,
                    saved_at: DateTime.from_unix!(mtime),
                    model: state.model,
                    status: state.status,
                    scope_root: state.scope_root,
                    size: size
                  }

                {:error, _} ->
                  nil
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
end
