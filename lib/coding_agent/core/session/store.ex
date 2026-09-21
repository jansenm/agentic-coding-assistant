defmodule CodingAgent.Core.Session.Store do
  @moduledoc """
  Session persistence (ADR 020/023): save and resume conversations.

  ADR 003 made the session state plain data precisely so this slice could
  exist: persisting is writing the state, resuming is reading it back —
  not an exception path.

  ## Engine

  One **SQLite database file per store** (ADR 020 R16); many sessions
  live inside it. The driver is `Exqlite.Sqlite3` — the one core-path
  NIF, isolated behind this module (ADR 023). Every `Exqlite` call stays
  in here; nothing else references it.

  The schema is small and deliberately not normalized yet:

      sessions(
        id TEXT PRIMARY KEY,
        format_version INTEGER,
        saved_at INTEGER,       -- unix seconds (list ordering, prune by age)
        model TEXT, status TEXT, scope_root TEXT,   -- the picker's columns
        size_bytes INTEGER,     -- the state blob's length (R13)
        state BLOB              -- the exact term_to_binary state
      )

  The full `%State{}` (context messages with their structs, policy,
  pending calls) round-trips as one BLOB, so the encoding is lossless
  without custom encoders. The metadata columns exist so that **listing
  reads columns, never decodes a state** — the ADR 020 ``R9``
  requirement (today's blob store decodes every session just to list
  four fields). The picker's ``:size`` is ``size_bytes``, not a
  ``File.stat``.

  Slice 4 normalizes the agent view and the display view into their own
  session-keyed tables (ADR 020); this slice keeps the state as a BLOB
  and changes only the *store shape* (one DB, columns for listing).

  ## Fail-closed

  A missing row, a foreign DB, a corrupt/too-new BLOB, or a wrong format
  version all return an error tuple, never a half state (``R5``) — the
  same discipline as the permission loader.
  """

  alias CodingAgent.Core.Session.{Scratch, State}
  alias Exqlite.Sqlite3

  require Logger

  @format_version 1

  # Columns read for a listing; deliberately no `state`.
  @summary_columns "id, saved_at, model, status, scope_root, size_bytes"

  # -- Store location ---------------------------------------------------------

  @doc """
  The store DB path (created, with its schema, on first use). Decided in
  `Core.Config` (one reader); this is the typed accessor.
  """
  @spec path() :: String.t()
  def path, do: CodingAgent.Core.Config.store_path()

  # -- Schema -----------------------------------------------------------------

  @schema """
  CREATE TABLE IF NOT EXISTS sessions (
    id             TEXT PRIMARY KEY,
    format_version INTEGER NOT NULL,
    saved_at       INTEGER NOT NULL,
    model          TEXT,
    status         TEXT,
    scope_root     TEXT,
    size_bytes     INTEGER NOT NULL,
    state          BLOB NOT NULL
  );
  CREATE INDEX IF NOT EXISTS sessions_saved_at ON sessions(saved_at DESC);
  CREATE INDEX IF NOT EXISTS sessions_scope ON sessions(scope_root);

  -- The display view (ADR 020): what the USER saw, append-only, never
  -- touched by compaction. Plain TEXT (searchable with SQL LIKE); the
  -- agent view lives in sessions.state and is never grepped.
  CREATE TABLE IF NOT EXISTS display (
    session_id TEXT NOT NULL,
    seq        INTEGER NOT NULL,
    kind       TEXT NOT NULL,   -- user|assistant|reasoning|tool|info
    text       TEXT NOT NULL,
    agent      TEXT,
    meta       TEXT,            -- kind-specific extras (e.g. tool name), as a term
    PRIMARY KEY (session_id, seq)
  );
  CREATE INDEX IF NOT EXISTS display_session ON display(session_id, seq);
  """

  # -- Persistence ------------------------------------------------------------

  @doc """
  Persists the session state (atomic upsert). Returns `:ok` or
  `{:error, reason}` — persistence failure never crashes the session;
  the in-memory session stays usable (``R7``).
  """
  @spec save(State.t()) :: :ok | {:error, term()}
  def save(%State{} = state) do
    payload = :erlang.term_to_binary({@format_version, state})

    with {:ok, db} <- open(),
         :ok <- write(db, state, payload) do
      close(db)
    else
      {:error, reason} ->
        Logger.warning("session store save failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp write(db, state, payload) do
    sql = """
    INSERT INTO sessions
      (id, format_version, saved_at, model, status, scope_root, size_bytes, state)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      format_version = excluded.format_version,
      saved_at       = excluded.saved_at,
      model          = excluded.model,
      status         = excluded.status,
      scope_root     = excluded.scope_root,
      size_bytes     = excluded.size_bytes,
      state          = excluded.state
    """

    params = [
      state.id,
      @format_version,
      now_ms(),
      state.model,
      to_string(state.status),
      state.scope_root,
      byte_size(payload),
      {:blob, payload}
    ]

    exec(db, sql, params)
  end

  defp now_ms, do: DateTime.to_unix(DateTime.utc_now(), :millisecond)

  # Test seam (like `Session.debug_gate`): insert a raw payload and/or an
  # explicit timestamp, to exercise corrupt/foreign/old-version loads and
  # list ordering without filesystem games. Not part of the store contract.
  @doc false
  @spec debug_put(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def debug_put(id, payload, opts \\ []) do
    blob =
      case Keyword.get(opts, :encode, true) do
        true -> :erlang.term_to_binary(payload)
        false -> payload
      end

    saved_at = Keyword.get(opts, :saved_at, now_ms())

    with {:ok, db} <- open() do
      result =
        exec(
          db,
          """
          INSERT INTO sessions
            (id, format_version, saved_at, model, status, scope_root, size_bytes, state)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET saved_at = excluded.saved_at, state = excluded.state
          """,
          [
            id,
            Keyword.get(opts, :format_version, @format_version),
            saved_at,
            Keyword.get(opts, :model),
            "idle",
            Keyword.get(opts, :scope_root),
            byte_size(blob),
            {:blob, blob}
          ]
        )

      close(db)
      result
    end
  end

  # Test seam: set a session's `saved_at` (unix ms) for list ordering.
  @doc false
  @spec debug_set_saved_at(String.t(), integer()) :: :ok | {:error, term()}
  def debug_set_saved_at(id, saved_at_ms) do
    with {:ok, db} <- open() do
      result = exec(db, "UPDATE sessions SET saved_at = ? WHERE id = ?", [saved_at_ms, id])
      close(db)
      result
    end
  end

  # -- The display view (ADR 020) ---------------------------------------------

  @typedoc "A display-view kind. `text` is plain text (the rendered form)."
  @type display_kind :: :user | :assistant | :reasoning | :tool | :info

  @doc """
  Appends one display event to a session, append-only (ADR 020). The
  display view is the immutable record of what the user saw; compaction
  never touches it. `meta` is an optional term for kind-specific extras
  (e.g. a tool name).

  Best-effort like `save/1`: a write failure logs and returns
  `{:error, _}`, never crashing the turn (``R7``).
  """
  @spec append_display(String.t(), display_kind(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def append_display(session_id, kind, text, opts \\ []) do
    agent = Keyword.get(opts, :agent)
    meta = Keyword.get(opts, :meta)
    meta_bin = if meta == nil, do: nil, else: :erlang.term_to_binary(meta)

    with {:ok, db} <- open() do
      result =
        exec(
          db,
          """
          INSERT INTO display (session_id, seq, kind, text, agent, meta)
          VALUES (?, (SELECT COALESCE(MAX(seq), -1) + 1 FROM display WHERE session_id = ?), ?, ?, ?, ?)
          """,
          [session_id, session_id, to_string(kind), text, agent, meta_bin]
        )

      close(db)

      case result do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("display append failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  The display view for a session, oldest first. The `text` is plain
  text; `meta` is decoded back to a term. Reads the immutable record —
  used to render a resumed transcript.
  """
  @spec display(String.t()) :: [map()]
  def display(session_id) do
    case open() do
      {:ok, db} ->
        result =
          case fetch_all(
                 db,
                 "SELECT seq, kind, text, agent, meta FROM display WHERE session_id = ? ORDER BY seq",
                 [session_id]
               ) do
            {:ok, rows} -> Enum.map(rows, &to_display_entry/1)
            {:error, _} -> []
          end

        close(db)
        result

      {:error, _} ->
        []
    end
  end

  # Test seam: write a display row with an arbitrary kind, to exercise
  # the unknown-kind degrade path.
  @doc false
  @spec debug_put_display(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def debug_put_display(session_id, kind, text) do
    with {:ok, db} <- open() do
      result =
        exec(
          db,
          "INSERT INTO display (session_id, seq, kind, text) VALUES (?, (SELECT COALESCE(MAX(seq), -1) + 1 FROM display WHERE session_id = ?), ?, ?)",
          [session_id, session_id, kind, text]
        )

      close(db)
      result
    end
  end

  defp to_display_entry([seq, kind, text, agent, meta_bin]) do
    %{
      seq: seq,
      kind: to_display_kind(kind),
      text: text,
      agent: agent,
      meta: decode_meta(meta_bin)
    }
  end

  # an unknown kind must not mint an atom from stored text; degrade to
  # :info (the harmless display kind) instead
  defp to_display_kind(kind) when kind in ~w(user assistant reasoning tool info),
    do: String.to_existing_atom(kind)

  defp to_display_kind(_), do: :info

  defp decode_meta(nil), do: nil

  defp decode_meta(bin) when is_binary(bin) do
    :erlang.binary_to_term(bin)
  rescue
    _ -> nil
  end

  @doc """
  Loads a persisted session. Fail-closed: anything unexpected — missing
  row, corrupt BLOB, wrong version — is an error tuple, never a half
  state.
  """
  @spec load(String.t()) :: {:ok, State.t()} | {:error, term()}
  def load(id) do
    with {:ok, db} <- open() do
      result = decode_row(db, id)
      close(db)
      result
    end
  end

  # The stored BLOB is the term_to_binary of {version, state}. Anything
  # else (corrupt bytes, foreign payload, wrong version) fails closed.
  # No [:safe]: a saved session legitimately contains provider atoms a new
  # VM has not interned (see the 4a lesson) — the trust domain is the
  # user's own store file, like .env/.bashrc.
  defp decode(blob) when is_binary(blob) do
    case :erlang.binary_to_term(blob) do
      {@format_version, %State{} = state} ->
        State.restore(state)

      {version, _} ->
        {:error, {:not_a_session_file, version}}

      other ->
        {:error, {:not_a_session_file, inspect(other)}}
    end
  rescue
    e -> {:error, {:corrupt_session, Exception.message(e)}}
  end

  defp decode(_), do: {:error, :corrupt_session}

  @doc """
  Resolves a session id that may be a PREFIX (unique): "1730" matches
  "tui-1730..." when exactly one session does. Ambiguous and missing
  ids are errors — never guesses (fail-closed, like load/1).
  """
  @spec resolve_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_id(id) do
    with {:ok, db} <- open() do
      result =
        case fetch_all(db, "SELECT id FROM sessions", []) do
          {:ok, rows} ->
            ids = Enum.map(rows, fn [id] -> id end)

            matching =
              Enum.filter(ids, fn s ->
                s == id or String.starts_with?(s, id) or String.ends_with?(s, id)
              end)

            case matching do
              [found] -> {:ok, found}
              [] -> {:error, :enoent}
              many -> {:error, {:ambiguous_id, many}}
            end

          {:error, reason} ->
            {:error, reason}
        end

      close(db)
      result
    end
  end

  @doc """
  Deletes a persisted session (best effort): its row, its display view
  (no orphans), and its scratch directory (ADR 022).
  """
  @spec delete(String.t()) :: :ok
  def delete(id) do
    with {:ok, db} <- open() do
      _ = exec(db, "DELETE FROM display WHERE session_id = ?", [id])
      _ = exec(db, "DELETE FROM sessions WHERE id = ?", [id])
      close(db)
    end

    Scratch.remove(Scratch.path(id))
    :ok
  end

  @doc """
  Renames a persisted session (one transaction: re-id the row, move the
  scratch). Intended for idle sessions — a live one keeps running under
  its old id and re-saves it on the next turn. Returns
  `{:ok, new_id}` or `{:error, reason}`.
  """
  def rename(id, new_id) when is_binary(new_id) do
    new_id = String.trim(new_id)

    cond do
      new_id == "" or new_id == id ->
        {:error, :invalid_name}

      # an id must stay a plain name (no path traversal, no hidden-file
      # collision); it is a primary key, but the scratch path derives from
      # it, so the guard stays explicit.
      not safe_id?(new_id) ->
        {:error, :invalid_name}

      true ->
        do_rename(id, new_id)
    end
  end

  # Re-id the row in one connection: refuse a collision, load the old
  # state, upsert under the new id, delete the old row, move the scratch
  # and tell a live process (via Session) so its next save follows.
  defp do_rename(id, new_id) do
    with {:ok, db} <- open() do
      result =
        case fetch_one(db, "SELECT 1 FROM sessions WHERE id = ?", [new_id]) do
          {:ok, row} when row != nil ->
            {:error, :exists}

          {:ok, nil} ->
            rename_row(db, id, new_id)

          {:error, reason} ->
            {:error, reason}
        end

      close(db)
      result
    end
  end

  defp rename_row(db, id, new_id) do
    case decode_row(db, id) do
      {:ok, state} ->
        new_state = struct!(state, id: new_id)

        with :ok <- write(db, new_state, :erlang.term_to_binary({@format_version, new_state})),
             # the display view is keyed by session_id too: re-key it so
             # a rename never orphans the transcript
             :ok <-
               exec(db, "UPDATE display SET session_id = ? WHERE session_id = ?", [new_id, id]),
             :ok <- exec(db, "DELETE FROM sessions WHERE id = ?", [id]) do
          Scratch.move(Scratch.path(id), Scratch.path(new_id))
          CodingAgent.Core.Session.notify_renamed(id, new_id)
          {:ok, new_id}
        end

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_row(db, id) do
    case fetch_one(db, "SELECT state FROM sessions WHERE id = ?", [id]) do
      {:ok, nil} -> {:error, :enoent}
      {:ok, [blob]} -> decode(blob)
      {:error, reason} -> {:error, reason}
    end
  end

  # A session id is a plain name: no path separators, no "..", no leading
  # dot (the scratch path is derived from it).
  @spec safe_id?(String.t()) :: boolean()
  defp safe_id?(id) do
    Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, id)
  end

  # -- Listing ----------------------------------------------------------------

  @doc """
  Lists persisted sessions, newest first. Each entry carries the storage
  footprint (`:size`, bytes — R13) and the persisted `:scope_root`.
  Reads columns only — never decodes a state (``R9``).
  """
  @spec list() :: [map()]
  def list, do: list_summaries("SELECT #{@summary_columns} FROM sessions ORDER BY saved_at DESC")

  @doc """
  Sessions for one working directory, newest first (the picker's
  this-dir view). Filters on the persisted scope_root column.
  """
  @spec list_in(String.t()) :: [map()]
  def list_in(root) do
    root = Path.expand(root)

    list_summaries(
      "SELECT #{@summary_columns} FROM sessions WHERE scope_root = ? ORDER BY saved_at DESC",
      [root]
    )
  end

  @spec list_summaries(String.t(), [term()]) :: [map()]
  defp list_summaries(sql, params \\ []) do
    case open() do
      {:ok, db} ->
        result =
          case fetch_all(db, sql, params) do
            {:ok, rows} -> Enum.map(rows, &to_summary/1)
            {:error, _} -> []
          end

        close(db)
        result

      {:error, _} ->
        []
    end
  end

  defp to_summary([id, saved_at_ms, model, status, scope_root, size]) do
    %{
      id: id,
      saved_at: DateTime.from_unix!(saved_at_ms, :millisecond),
      model: model,
      status: to_status(status),
      scope_root: scope_root,
      size: size || 0
    }
  end

  # status is persisted as text; an unknown value degrades to :idle rather
  # than minting an atom from file content.
  defp to_status(nil), do: :idle

  defp to_status(status) when status in ~w(idle running interrupted error),
    do: String.to_existing_atom(status)

  defp to_status(_), do: :idle

  # -- The one place Exqlite is touched ---------------------------------------

  defp open do
    db_path = path()
    File.mkdir_p!(Path.dirname(db_path))

    # busy_timeout FIRST: it is per-connection and must be in force before
    # any statement that can block. Setting journal_mode (a write) before
    # it let concurrent opens hit "database is locked" with no timeout.
    case Sqlite3.open(db_path) do
      {:ok, db} ->
        case setup(db) do
          :ok ->
            {:ok, db}

          {:error, reason} ->
            # don't leak a half-opened handle (it can hold a lock)
            Sqlite3.close(db)
            {:error, {:store_open_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:store_open_failed, reason}}
    end
  end

  defp setup(db) do
    with :ok <- Sqlite3.execute(db, "PRAGMA busy_timeout=5000"),
         :ok <- Sqlite3.execute(db, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(db, @schema) do
      :ok
    end
  end

  defp close(db), do: Sqlite3.close(db)

  # Write (insert/update/delete) with params; returns :ok or {:error, _}.
  defp exec(db, sql, params) do
    case Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        try do
          :ok = Sqlite3.bind(stmt, params)
          :done = Sqlite3.step(db, stmt)
          :ok
        after
          Sqlite3.release(db, stmt)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all(db, sql, params) do
    with {:ok, stmt} <- Sqlite3.prepare(db, sql) do
      try do
        :ok = Sqlite3.bind(stmt, params)
        Sqlite3.fetch_all(db, stmt)
      after
        Sqlite3.release(db, stmt)
      end
    end
  end

  defp fetch_one(db, sql, params) do
    case fetch_all(db, sql, params) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row | _]} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end
end
