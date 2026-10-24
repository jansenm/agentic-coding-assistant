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

  The schema is the dual view from ADR 020:

      sessions(                        -- one row per session (metadata)
        id TEXT PRIMARY KEY,
        format_version INTEGER,
        saved_at INTEGER,       -- unix seconds (list ordering, prune by age)
        model TEXT, status TEXT, scope_root TEXT,   -- the picker's columns
        size_bytes INTEGER,     -- whole footprint incl. message rows (R13)
        state BLOB              -- the %State{} WITHOUT its context
      )
      messages(session_id, seq, data BLOB)  -- the agent view: one row per
                                            -- context message; compaction
                                            -- mutates THIS
      display(session_id, seq, kind, text, agent, meta)  -- immutable record

  The **agent view** (the context the next request is built from) is one
  `messages` row per `ReqLLM.Message`, each that message's exact
  `term_to_binary`. The row is the appendable/addressable unit: appending
  a turn is one `INSERT`, compaction a seq-range rewrite of the changed
  suffix, instead of re-serializing the whole context at every boundary.
  The `sessions.state` BLOB holds the rest of `%State{}` (policy, pending
  calls, usage) — small and rarely the bulk.

  The metadata columns exist so that **listing reads columns, never
  decodes a state** — the ADR 020 ``R9`` requirement. The picker's
  ``:size`` is ``size_bytes``, not a ``File.stat``.

  ``@format_version`` 2 is this split: a v1 blob (context inside) fails
  closed on load, so a pre-3b-ii session is deleted, not silently read
  with an empty context (one user, unreleased).

  ## Evolving a persisted struct

  The version covers the payload's shape, not the shapes INSIDE it: a
  ``%State{}`` carrying a ``%Usage{}`` that gained a field is still
  version 2, and `binary_to_term/1` hands back the old field set with no
  warning. Two rules, both cheap to follow:

    * **Additive is free.** A new persisted field WITH A DEFAULT is healed
      on read by the struct's `from_map/1` (it compares the key count with
      the current shape and fills what an older build did not write). Pin
      the new name in `store_test`'s shape lock and do NOT bump the
      version.
    * **Anything else costs a version.** Removing, renaming, retyping or
      changing the MEANING of a persisted field is a format change: bump
      ``@format_version``, and every older snapshot fails closed at load
      with "not a session file". That is the honest outcome — the picker
      offers a fresh session instead of resuming half-understood state.

  This rule exists because of one bug: `%Usage{}` gained `cached_tokens`
  and `from_map/1`'s fast path kept returning the old four-key struct, so
  the sidebar raised `KeyError` on every frame while the session itself
  was intact. Additive fields are cheap; silence about them is not.

  ## Fail-closed

  A missing row, a foreign DB, a corrupt/too-new BLOB, or a wrong format
  version all return an error tuple, never a half state (``R5``) — the
  same discipline as the permission loader.
  """

  alias CodingAgent.Core.Session.{Scratch, State}
  alias Exqlite.Sqlite3
  alias ReqLLM.Context

  require Logger

  # Versions the agent-view encoding. v2 (ADR 020 slice 3b-ii) moves the
  # context messages OUT of the state BLOB into the `messages` table, so
  # a `sessions.state` BLOB is now the state WITHOUT its context. A v1
  # blob therefore fails closed (its context would be silently empty);
  # there is no compatibility reader — a pre-v2 session is deleted, not
  # migrated (one user, unreleased). The messages' own encoding is that
  # message's term_to_binary, versioned by this same constant.
  #
  # EVOLUTION RULE (see "Evolving a persisted struct" in the moduledoc):
  # a new field with a default inside a persisted struct is healed by
  # `from_map/1` and does NOT bump this; any other change to a persisted
  # struct's shape (remove, rename, retype, reinterpret) DOES. A bump makes
  # every older snapshot fail closed — which is the point.
  @format_version 2

  # Columns read for a listing; deliberately no `state`.
  @summary_columns "id, saved_at, model, status, scope_root, size_bytes"

  # The SQLite SCHEMA version (ADR 020, "Schema versioning"). Independent
  # of @format_version, which versions the agent-view BLOB's shape. This
  # one is stored in the DB header via `PRAGMA user_version` — the
  # idiomatic SQLite slot, no extra table.
  @schema_version 2

  # -- Store location ---------------------------------------------------------

  @doc """
  The store DB path (created, with its schema, on first use). Decided in
  `Core.Config` (one reader); this is the typed accessor.
  """
  @spec path() :: String.t()
  def path, do: CodingAgent.Core.Config.store_path()

  # -- Schema -----------------------------------------------------------------

  # Ordered, forward-only migrations (ADR 020, "Schema versioning").
  # Append only; never edit a shipped entry. `migrate/1` runs the pending
  # ones in a transaction, then stamps `PRAGMA user_version`. v1 is the
  # original slice-3a schema (idempotent, so it also converges an old store
  # that predates the version marker).
  defp migrations do
    [
      {1, &migrate_v1/1},
      {2, &migrate_v2/1}
    ]
  end

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

  # The agent view (ADR 020 slice 3b-ii): the context messages, one row
  # PER MESSAGE, each the exact `term_to_binary` of that `ReqLLM.Message`.
  # This is the compaction-mutable side (the display view above is the
  # immutable record). The row is the appendable/addressable unit, so
  # appending a turn is one INSERT and compaction is a seq-range delete,
  # instead of rewriting the whole context on every boundary.
  @messages_schema """
  CREATE TABLE IF NOT EXISTS messages (
    session_id TEXT NOT NULL,
    seq        INTEGER NOT NULL,
    data       BLOB NOT NULL,
    PRIMARY KEY (session_id, seq)
  );
  """

  # -- Persistence ------------------------------------------------------------

  @doc """
  Persists the session state (atomic upsert). Returns `:ok` or
  `{:error, reason}` — persistence failure never crashes the session;
  the in-memory session stays usable (``R7``).

  ADR 020 slice 3b-ii: the agent view's context lives in the
  `messages` table (one row per message) and the `sessions.state` BLOB
  holds everything BUT the context. Appending a turn writes one message
  row; compaction deletes a seq range. Both the metadata row and the
  message rows are written in ONE transaction, so a crash never leaves
  them disagreeing.
  """
  @spec save(State.t()) :: :ok | {:error, term()}
  def save(%State{} = state) do
    encoded = state.context |> Context.to_list() |> Enum.map(&:erlang.term_to_binary/1)
    base = %{state | context: Context.new()}
    payload = :erlang.term_to_binary({@format_version, base})

    # The metadata row and the message rows must land together or not at
    # all (a half-save is a session that lists but loads with an
    # empty/partial context). Any failure ROLLBACKs: an abandoned open
    # write transaction holds a lock and would wedge later writes.
    result =
      with_db(fn db ->
        transaction(db, fn ->
          with :ok <- write(db, state, payload, encoded),
               :ok <- sync_messages(db, state.id, encoded) do
            :ok
          end
        end)
      end)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("session store save failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # size_bytes is the whole session footprint: the metadata BLOB PLUS the
  # message rows it no longer contains (the picker's R13 figure).
  defp write(db, state, payload, encoded_messages) do
    message_bytes = Enum.reduce(encoded_messages, 0, fn b, acc -> acc + byte_size(b) end)

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
      byte_size(payload) + message_bytes,
      {:blob, payload}
    ]

    exec(db, sql, params)
  end

  # Bring the stored message rows in line with the in-memory list. The
  # common PREFIX (unchanged bytes at unchanged indexes) is left on disk;
  # everything from the first difference is rewritten with DENSE seqs.
  #
  # Rewriting from the first difference (not just the changed span) keeps
  # `seq` dense and monotonic, which is what ORDER BY seq requires. The
  # rewrite is bounded by the changed suffix: an append rewrites nothing
  # (prefix = all stored rows) and writes only the new messages, while
  # compaction rewrites one summary plus the recent tail (kept short by
  # the compaction boundary). The bulk history — the prefix — is never
  # touched. Correct for every mutation (append, compaction's prefix
  # rewrite, an agent switch replacing the system message in place),
  # because it compares actual bytes.
  defp sync_messages(db, session_id, encoded) do
    case fetch_all(db, "SELECT data FROM messages WHERE session_id = ? ORDER BY seq", [session_id]) do
      {:ok, rows} ->
        stored = Enum.map(rows, fn [data] -> data end)
        prefix = common_prefix_len(stored, encoded)
        tail = Enum.slice(encoded, prefix, length(encoded) - prefix)

        with :ok <- delete_message_range(db, session_id, prefix, length(stored)),
             :ok <- insert_messages(db, session_id, prefix, tail) do
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp common_prefix_len(old, new), do: common_prefix_len(old, new, 0)

  defp common_prefix_len([a | old], [a | new], n), do: common_prefix_len(old, new, n + 1)
  defp common_prefix_len(_old, _new, n), do: n

  # [from, to) — an empty range is a no-op
  defp delete_message_range(_db, _session_id, from, to) when to <= from, do: :ok

  defp delete_message_range(db, session_id, from, to) do
    exec(
      db,
      "DELETE FROM messages WHERE session_id = ? AND seq >= ? AND seq < ?",
      [session_id, from, to]
    )
  end

  defp insert_messages(_db, _session_id, _start, []), do: :ok

  defp insert_messages(db, session_id, start, blobs) do
    Enum.reduce_while(Enum.with_index(blobs, start), :ok, fn {blob, seq}, _acc ->
      case exec(
             db,
             "INSERT OR REPLACE INTO messages (session_id, seq, data) VALUES (?, ?, ?)",
             [session_id, seq, {:blob, blob}]
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

    with_db(fn db ->
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
    end)
  end

  # Test seam (ADR 020 3b-ii): the stored message-row count, so a test can
  # assert one row per message and that delete/rename keep them consistent.
  @doc false
  @spec debug_message_count(String.t()) :: non_neg_integer()
  def debug_message_count(id) do
    with_db(fn db ->
      case fetch_one(db, "SELECT count(*) FROM messages WHERE session_id = ?", [id]) do
        {:ok, [n]} -> n
        _ -> 0
      end
    end)
  end

  # Test seam (ADR 020 3b-ii): the metadata state exactly as stored, with
  # NO context reattached — proves the split (the BLOB no longer carries
  # the agent view). Not part of the store contract.
  @doc false
  @spec debug_raw_state(String.t()) :: {:ok, State.t()} | {:error, term()}
  def debug_raw_state(id), do: with_db(fn db -> decode_row(db, id) end)

  # Test seam (ADR 020 3b-ii): write a raw message row, to exercise a
  # corrupt agent view without hand-editing a SQLite file.
  @doc false
  @spec debug_put_message(String.t(), non_neg_integer(), term(), keyword()) ::
          :ok | {:error, term()}
  def debug_put_message(session_id, seq, payload, opts \\ []) do
    blob =
      case Keyword.get(opts, :encode, true) do
        true -> :erlang.term_to_binary(payload)
        false -> payload
      end

    with_db(fn db ->
      exec(
        db,
        "INSERT OR REPLACE INTO messages (session_id, seq, data) VALUES (?, ?, ?)",
        [session_id, seq, {:blob, blob}]
      )
    end)
  end

  # Test seam: set a session's `saved_at` (unix ms) for list ordering.
  @doc false
  @spec debug_set_saved_at(String.t(), integer()) :: :ok | {:error, term()}
  def debug_set_saved_at(id, saved_at_ms) do
    with_db(fn db ->
      exec(db, "UPDATE sessions SET saved_at = ? WHERE id = ?", [saved_at_ms, id])
    end)
  end

  # Test seams for the schema version (ADR 020, "Schema versioning"). They
  # let a test plant an old/new store without hand-editing a SQLite file.
  @doc false
  @spec debug_user_version() :: {:ok, non_neg_integer()} | {:error, term()}
  def debug_user_version, do: with_db(fn db -> user_version(db) end)

  @doc false
  @spec debug_set_user_version(non_neg_integer()) :: :ok | {:error, term()}
  def debug_set_user_version(version) when is_integer(version) and version >= 0 do
    result = with_db(fn db -> set_user_version(db, version) end)
    # the migration check runs at OPEN; drop the cached handle so the next
    # operation reopens and reacts to the planted version (the seam's whole
    # point: "an old/new version is seen on the next open")
    invalidate()
    result
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

    result =
      with_db(fn db ->
        exec(
          db,
          """
          INSERT INTO display (session_id, seq, kind, text, agent, meta)
          VALUES (?, (SELECT COALESCE(MAX(seq), -1) + 1 FROM display WHERE session_id = ?), ?, ?, ?, ?)
          """,
          [session_id, session_id, to_string(kind), text, agent, meta_bin]
        )
      end)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("display append failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  The display view for a session, oldest first. The `text` is plain
  text; `meta` is decoded back to a term. Reads the immutable record —
  used to render a resumed transcript.
  """
  @spec display(String.t()) :: [map()]
  def display(session_id) do
    case with_db(fn db ->
           fetch_all(
             db,
             "SELECT seq, kind, text, agent, meta FROM display WHERE session_id = ? ORDER BY seq",
             [session_id]
           )
         end) do
      {:ok, rows} -> Enum.map(rows, &to_display_entry/1)
      _ -> []
    end
  end

  @doc """
  Store-wide full-text search over the display view (ADR 020 ``S1``: "in
  which sessions did I touch X"). Case-insensitive substring match
  (SQLite ``LIKE``), newest session first, matches oldest-first within a
  session. Returns one entry per MATCHING session:

      %{id, saved_at, model, status, scope_root, size, matches: [%{seq, kind, text, agent}]}

  Only the display view is searched — the immutable, plain-text record
  the user actually saw. The agent view is not grepped by design
  (``S4``/*encoding decision*). An empty/blank query returns `[]` rather
  than every row.
  """
  @spec search(String.t()) :: [map()]
  def search(query) when is_binary(query) do
    case String.trim(query) do
      "" ->
        []

      needle ->
        pattern = "%" <> escape_like(needle) <> "%"

        case with_db(fn db ->
               fetch_all(
                 db,
                 """
                 SELECT s.id, s.saved_at, s.model, s.status, s.scope_root, s.size_bytes,
                        d.seq, d.kind, d.text, d.agent
                 FROM display d
                 JOIN sessions s ON s.id = d.session_id
                 WHERE d.text LIKE ? ESCAPE '\\'
                 ORDER BY s.saved_at DESC, d.seq ASC
                 """,
                 [pattern]
               )
             end) do
          {:ok, rows} -> group_matches(rows)
          _ -> []
        end
    end
  end

  # LIKE wildcards in the QUERY are literals, not operators: a search for
  # "100%" must not match everything. Escape the wildcard and the escape
  # char itself (paired with the ESCAPE '\' clause).
  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp group_matches(rows) do
    rows
    |> Enum.reduce([], fn [id, saved_at, model, status, scope_root, size, seq, kind, text, agent],
                          acc ->
      match = %{seq: seq, kind: to_display_kind(kind), text: text, agent: agent}

      case acc do
        [%{id: ^id} = head | rest] ->
          [%{head | matches: head.matches ++ [match]} | rest]

        _ ->
          [to_search_entry(id, saved_at, model, status, scope_root, size, match) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp to_search_entry(id, saved_at, model, status, scope_root, size, match) do
    %{
      id: id,
      saved_at: DateTime.from_unix!(saved_at, :millisecond),
      model: model,
      status: to_status(status),
      scope_root: scope_root,
      size: size || 0,
      matches: [match]
    }
  end

  # Test seam: write a display row with an arbitrary kind, to exercise
  # the unknown-kind degrade path.
  @doc false
  @spec debug_put_display(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def debug_put_display(session_id, kind, text) do
    with_db(fn db ->
      exec(
        db,
        "INSERT INTO display (session_id, seq, kind, text) VALUES (?, (SELECT COALESCE(MAX(seq), -1) + 1 FROM display WHERE session_id = ?), ?, ?)",
        [session_id, session_id, kind, text]
      )
    end)
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
  def load(id), do: with_db(fn db -> decode_row_with_context(db, id) end)

  # The stored BLOB is the term_to_binary of {version, state}, where the
  # state carries NO context (ADR 020 3b-ii): the messages live in their
  # own rows and are reattached by `decode_row/2`. Anything else (corrupt
  # bytes, foreign payload, wrong version — including a pre-3b-ii v1 blob
  # whose context would otherwise be silently empty) fails closed.
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

  # Rebuild a session: the metadata state from its BLOB, the context from
  # the message rows. A message row that will not decode is a corrupt
  # session (fail closed) — never a silently truncated context.
  defp decode_row_with_context(db, id) do
    with {:ok, state} <- decode_row(db, id),
         {:ok, messages} <- read_messages(db, id) do
      {:ok, %{state | context: Context.new(messages)}}
    end
  end

  defp read_messages(db, id) do
    case fetch_all(db, "SELECT data FROM messages WHERE session_id = ? ORDER BY seq", [id]) do
      {:ok, rows} ->
        Enum.reduce_while(rows, {:ok, []}, fn [blob], {:ok, acc} ->
          case decode_message(blob) do
            {:ok, msg} -> {:cont, {:ok, [msg | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, rev} -> {:ok, Enum.reverse(rev)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_message(blob) when is_binary(blob) do
    case :erlang.binary_to_term(blob) do
      %ReqLLM.Message{} = msg -> {:ok, msg}
      other -> {:error, {:corrupt_message, inspect(other, printable_limit: 60)}}
    end
  rescue
    e -> {:error, {:corrupt_message, Exception.message(e)}}
  end

  defp decode_message(_), do: {:error, :corrupt_message}

  @doc """
  Every persisted session id. Used by the checkpoint reconciliation pass
  (review N54): a ref whose session id is not among these (and is not
  live) is an orphan.
  """
  @spec ids() :: [String.t()]
  def ids do
    with_db(fn db ->
      case fetch_all(db, "SELECT id FROM sessions", []) do
        {:ok, rows} -> Enum.map(rows, fn [id] -> id end)
        _ -> []
      end
    end)
  end

  @doc """
  Resolves a session id that may be a PREFIX (unique): "1730" matches
  "tui-1730..." when exactly one session does. Ambiguous and missing
  ids are errors — never guesses (fail-closed, like load/1).
  """
  @spec resolve_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_id(id) do
    with_db(fn db ->
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
    end)
  end

  @doc """
  Deletes a persisted session (best effort): its row, its message rows
  and display rows (no orphans), its scratch directory (ADR 022), and its
  git checkpoint refs (ADR 036).
  """
  @spec delete(String.t()) :: :ok
  def delete(id) do
    # Read the state BEFORE the row goes, so the checkpoint refs (which
    # live in the scope repo, not the store) can be dropped with the
    # right scope root. Best effort: an unreadable/missing session has no
    # refs to clean.
    checkpoints = checkpoints_for_cleanup(id)

    with_db(fn db ->
      _ = exec(db, "DELETE FROM messages WHERE session_id = ?", [id])
      _ = exec(db, "DELETE FROM display WHERE session_id = ?", [id])
      _ = exec(db, "DELETE FROM sessions WHERE id = ?", [id])
      :ok
    end)

    Scratch.remove(Scratch.path(id))
    drop_checkpoints(checkpoints)
    :ok
  end

  # The (scope, checkpoint) pairs a session's refs need to be dropped.
  defp checkpoints_for_cleanup(id) do
    case load(id) do
      {:ok, %State{scope_root: root, checkpoints: cps}} when is_binary(root) and cps != [] ->
        %{root: root, checkpoints: cps}

      # Readable state, no refs to drop: the common, benign case (a fresh
      # session, or one that never took a snapshot). Silent.
      {:ok, %State{}} ->
        nil

      # Never persisted (a `persist?: false` session, e.g. a subagent):
      # there is no state, and therefore no refs. Benign, silent.
      {:error, :enoent} ->
        nil

      # The state exists but would not decode. This must not look like
      # "no refs" (review N55): a corrupt/foreign state may hold refs this
      # call can no longer name, so they would leak silently. Loud at
      # warning — the same level as this module's sibling failures (review
      # N62) — and the reconciliation pass (Checkpoint.reconcile/2, run off
      # the next session start) is the backstop this names.
      other ->
        Logger.warning(
          "checkpoint refs not cleaned for #{id}: state unreadable " <>
            "(#{inspect(other)}); reconciliation will collect them"
        )

        nil
    end
  end

  # Best effort: a repo that is gone (or a host without git) must not make
  # deleting a session fail.
  defp drop_checkpoints(nil), do: :ok

  defp drop_checkpoints(%{root: root, checkpoints: cps}) do
    scope = %{root: root}
    Enum.each(cps, &CodingAgent.Core.Checkpoint.drop(scope, &1))
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
  # state, upsert under the new id, delete the old row and move the
  # scratch.
  #
  # Telling a live process under the old id (`Session.notify_renamed/2`)
  # happens AFTER the call returns, i.e. OUTSIDE the store process.
  # `with_db` runs its fun INSIDE the Store GenServer, and that
  # notification is a synchronous call into the session — which calls
  # `Store.save/1` from inside its own `handle_call` while a turn runs.
  # Notifying from in there is a lock inversion (Store -> Session while
  # the Session -> Store) with `:infinity` waits on both sides: a rename
  # of a live session deadlocks the store behind it.
  defp do_rename(id, new_id) do
    result =
      with_db(fn db ->
        case fetch_one(db, "SELECT 1 FROM sessions WHERE id = ?", [new_id]) do
          {:ok, row} when row != nil ->
            {:error, :exists}

          {:ok, nil} ->
            rename_row(db, id, new_id)

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case result do
      {:ok, renamed} ->
        CodingAgent.Core.Session.notify_renamed(id, renamed)
        {:ok, renamed}

      other ->
        other
    end
  end

  defp rename_row(db, id, new_id) do
    case decode_row_with_context(db, id) do
      {:ok, state} ->
        new_state = struct!(state, id: new_id)

        encoded =
          new_state.context |> Context.to_list() |> Enum.map(&:erlang.term_to_binary/1)

        base = %{new_state | context: Context.new()}

        with :ok <-
               write(db, new_state, :erlang.term_to_binary({@format_version, base}), encoded),
             # the messages and display views are keyed by session_id too:
             # re-key them so a rename never orphans either view
             :ok <-
               exec(db, "UPDATE messages SET session_id = ? WHERE session_id = ?", [new_id, id]),
             :ok <-
               exec(db, "UPDATE display SET session_id = ? WHERE session_id = ?", [new_id, id]),
             :ok <- exec(db, "DELETE FROM sessions WHERE id = ?", [id]) do
          Scratch.move(Scratch.path(id), Scratch.path(new_id))
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
    case with_db(fn db -> fetch_all(db, sql, params) end) do
      {:ok, rows} -> Enum.map(rows, &to_summary/1)
      _ -> []
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

  # -- The store process: connection ownership --------------------------------

  # This module is a GenServer that OWNS one SQLite connection per store
  # path, and all DB work runs inside it (`with_db/1`). That is the fix for
  # the flaky `"database is locked"` failures.
  #
  # Why: the store began as a stateless module (a port of the earlier FILE
  # store, where one action was one `File.read`/`write`). The port kept the
  # shape — `open()` per call, statements, close — so every call opened its
  # OWN connection and the test suite's many processes raced one file.
  # SQLite's busy handler is unfair, so waiters starved even after a 5s
  # `busy_timeout` (measured: 29 of 32 concurrent writers failed). Owning
  # one connection removes the race by construction: this VM never presents
  # SQLite a second connection.
  #
  # It also removes real overhead: `open`+pragmas+`close` measured ~335us
  # against ~14us for a statement on a warm handle.
  #
  # The connection is opened LAZILY and cached, keyed by `(path, inode)`:
  # a changed path (a test switches `:store_path`) or a REPLACED file (a
  # test `rm -rf`s a path that stays constant across tests) is detected and
  # the handle reopened, so a stale handle never serves a deleted inode.
  #
  # The store is low-frequency, so one serialisation point is not a
  # throughput concern.

  use GenServer

  @doc false
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(nil), do: {:ok, %{path: nil, db: nil, inode: nil}}

  @impl true
  def handle_call({:with_db, fun}, _from, state) do
    case ensure_open(state) do
      {:ok, db, state} -> {:reply, run_fun(fun, db), state}
      {:error, reason, state} -> {:reply, {:error, {:store_open_failed, reason}}, state}
    end
  end

  # Drop the cached handle so the next operation reopens (and re-runs
  # `migrate/1`). Used by the debug seams that tamper with the store file
  # underneath the cache — the schema-version seams plant a version and
  # expect the NEXT open to react to it.
  @impl true
  def handle_call(:invalidate, _from, state) do
    close_current(state)
    {:reply, :ok, %{state | path: nil, db: nil, inode: nil}}
  end

  # Run a store operation with the cached connection, INSIDE the store
  # process (so access is serialised). Returns the fun's value, or an error
  # tuple when the store cannot be opened or the fun raises.
  defp with_db(fun), do: GenServer.call(__MODULE__, {:with_db, fun}, :infinity)

  @doc false
  def invalidate, do: GenServer.call(__MODULE__, :invalidate, :infinity)

  defp run_fun(fun, db) do
    fun.(db)
  rescue
    e ->
      Logger.error("store operation raised: #{Exception.message(e)}")
      {:error, {:store_exception, Exception.message(e)}}
  end

  defp ensure_open(%{path: p, db: db, inode: cached} = state) do
    current = path()

    if db != nil and p == current and cached == inode_of(current) do
      {:ok, db, state}
    else
      close_current(state)

      case open(current) do
        {:ok, db} ->
          {:ok, db, %{state | path: current, db: db, inode: inode_of(current)}}

        {:error, reason} ->
          {:error, reason, %{state | path: nil, db: nil, inode: nil}}
      end
    end
  end

  defp close_current(%{db: nil}), do: :ok
  defp close_current(%{db: db}), do: Sqlite3.close(db)

  # Identity of the file at `path`: its inode, or `:missing`. A replaced
  # file gets a new inode, so a cached handle is not reused for the deleted
  # one. `nil` on a platform that reports no inode — then only the path
  # identity applies.
  defp inode_of(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.inode
      {:error, _} -> :missing
    end
  end

  defp open(db_path) do
    File.mkdir_p!(Path.dirname(db_path))

    # busy_timeout FIRST: it is per-connection and must be in force before
    # any statement that can block.
    case Sqlite3.open(db_path) do
      {:ok, db} ->
        case setup(db) do
          :ok ->
            {:ok, db}

          {:error, reason} ->
            # don't leak a half-opened handle (it can hold a lock)
            Sqlite3.close(db)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp setup(db) do
    with :ok <- Sqlite3.execute(db, "PRAGMA busy_timeout=5000"),
         :ok <- Sqlite3.execute(db, "PRAGMA journal_mode=WAL") do
      migrate(db)
    end
  end

  # Bring the store up to @schema_version, or fail closed if it was
  # written by a newer build (we cannot know how to read it). Additive
  # migrations are idempotent, so a store predating the version marker
  # (user_version = 0) and a fresh store both converge on v1.
  defp migrate(db) do
    with {:ok, version} <- user_version(db) do
      cond do
        version == @schema_version ->
          :ok

        version > @schema_version ->
          {:error, {:store_schema_too_new, version, @schema_version}}

        true ->
          run_migrations(db, version)
      end
    end
  end

  defp run_migrations(db, from) do
    pending = Enum.filter(migrations(), fn {v, _} -> v > from end)

    # The list must cover every step from 1..@schema_version contiguously;
    # otherwise we could stamp a version having skipped a migration (e.g.
    # bumping @schema_version without appending, or leaving a gap).
    if Enum.map(migrations(), fn {v, _} -> v end) != Enum.to_list(1..@schema_version) do
      {:error, {:migration_list_incomplete, @schema_version}}
    else
      do_run_migrations(db, pending)
    end
  end

  defp do_run_migrations(db, pending) do
    with :ok <- Sqlite3.execute(db, "BEGIN"),
         {:ok, _} <- run_each(db, pending),
         :ok <- set_user_version(db, @schema_version),
         :ok <- Sqlite3.execute(db, "COMMIT") do
      :ok
    else
      {:error, reason} ->
        Sqlite3.execute(db, "ROLLBACK")
        {:error, {:store_migration_failed, reason}}
    end
  end

  defp run_each(db, pending) do
    Enum.reduce_while(pending, {:ok, nil}, fn {v, fun}, _acc ->
      case run_one(db, v, fun) do
        :ok -> {:cont, {:ok, nil}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_one(db, version, fun) do
    case fun.(db) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:migration_at, version, reason}}
    end
  end

  defp migrate_v1(db), do: Sqlite3.execute(db, @schema)

  # v2 adds the per-message agent-view table. Purely additive DDL; no
  # data move (there is no v1 reader — see @format_version).
  defp migrate_v2(db), do: Sqlite3.execute(db, @messages_schema)

  defp user_version(db) do
    case fetch_one(db, "PRAGMA user_version", []) do
      {:ok, [version]} when is_integer(version) -> {:ok, version}
      {:ok, _} -> {:error, :unreadable_user_version}
      {:error, reason} -> {:error, reason}
    end
  end

  defp set_user_version(db, version) do
    # PRAGMA does not accept bound params; @schema_version is a compile-time
    # integer, so interpolation is safe here.
    Sqlite3.execute(db, "PRAGMA user_version = #{version}")
  end

  # Run `fun` inside a write transaction. `fun` returns `:ok` or
  # `{:error, _}`; on any other result (or failure) we ROLLBACK, so the
  # connection never keeps an open write transaction — that leak is what
  # once made every later write fail.
  defp transaction(db, fun) do
    case Sqlite3.execute(db, "BEGIN IMMEDIATE") do
      :ok ->
        case fun.() do
          :ok ->
            case Sqlite3.execute(db, "COMMIT") do
              :ok ->
                :ok

              {:error, reason} ->
                _ = Sqlite3.execute(db, "ROLLBACK")
                {:error, reason}
            end

          {:error, reason} ->
            _ = Sqlite3.execute(db, "ROLLBACK")
            {:error, reason}

          other ->
            _ = Sqlite3.execute(db, "ROLLBACK")
            {:error, {:unexpected_tx_result, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Write (insert/update/delete) with params; returns :ok or {:error, _}.
  #
  # A constraint violation makes `step/2` return `{:error, reason}`, NOT
  # `:done` — so it must be matched, not asserted. Asserting (`:done =`)
  # raised a MatchError that a caller's `with` could not catch, leaving a
  # transaction open (found by forcing a NOT NULL violation: the leaked
  # write lock then failed every later save after busy_timeout).
  defp exec(db, sql, params) do
    case Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        try do
          with :ok <- Sqlite3.bind(stmt, params) do
            case Sqlite3.step(db, stmt) do
              :done -> :ok
              {:row, _} -> :ok
              {:error, reason} -> {:error, reason}
              other -> {:error, {:unexpected_step_result, other}}
            end
          end
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
        case Sqlite3.bind(stmt, params) do
          :ok -> Sqlite3.fetch_all(db, stmt)
          {:error, reason} -> {:error, reason}
        end
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
