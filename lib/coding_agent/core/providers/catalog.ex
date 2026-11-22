# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Providers.Catalog do
  @moduledoc """
  The model-catalog boundary: llm_db's model metadata, owned by one
  supervised process.

  llm_db stores its catalog in `:persistent_term` and loads it lazily on
  the first query. That lazy load is expensive (JSON-decoding the
  version-pinned ~8 MB snapshot: measured ~3.7 s cold) and takes a
  **global** load lock while it runs. Resolving it inline on the session
  mount path therefore blocked `Session.init` for seconds — the startup
  hang, because the only value the agent actually needs from the catalog
  is the model's context window (ADR 037), and that is not needed until a
  turn runs.

  This process owns the catalog LIFECYCLE and is the single access point for
  our code: nobody calls `LLMDB` directly. Reads are lock-free (they read
  llm_db's `:persistent_term` snapshot) and never queue behind a load, so a
  mount that races the warm gets `:loading` and falls back instead of
  blocking. llm_db swaps the snapshot atomically by digest, so readers keep
  seeing a consistent one.

  It loads the copy `Catalog.Refresh` owns under `state_dir()` when that copy
  is loadable, and llm_db's packaged snapshot otherwise (ADR 039 amendment
  2026-10-18 (2)). The refresh itself — fetch, re-cut for the installed pin,
  verify, rename — runs here too, on a daily timer and on `/catalog`; it never
  blocks a mount, because reads do not touch this process.
  """

  use GenServer

  require Logger

  alias CodingAgent.Core.Providers.Catalog.Refresh

  # The same registry the session events use (started by the application),
  # under a global key: the catalog is process-wide, not session-scoped.
  @registry CodingAgent.EventRegistry
  @key {:catalog_events, :all}

  @doc """
  Starts the catalog owner. Warms llm_db in a `handle_continue`, so
  application boot returns immediately.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether the catalog has loaded (a failed load reads as not ready)."
  @spec ready?() :: boolean()
  def ready?, do: LLMDB.snapshot() != nil

  @doc """
  How old the catalog's own data is, for display: `"2026-08-23 (56d)"`.

  The snapshot is a PACKAGED file, cut by llm_db's release cadence, so it
  is routinely weeks or months behind the providers it describes — a
  cloud model released since the cut is simply absent, and its window
  falls back to the 500k guess (review N106). Dating the source beside the
  `(assumed)` marker is what makes that diagnosable instead of a hunch.

  `"unknown"` while the catalog is cold or when the snapshot carries no
  date, so a caller never has to branch: this is a display string.
  """
  @spec snapshot_age() :: String.t()
  def snapshot_age do
    case snapshot_meta() do
      %{source_generated_at: at} when is_binary(at) -> age_label(at)
      _ -> "unknown"
    end
  end

  # `:meta` is where llm_db keeps the snapshot's own provenance;
  # `:source_generated_at` is when the DATA was cut, not when this process
  # loaded it (`:loaded_at`), and the former is the honest age to show.
  defp snapshot_meta do
    case LLMDB.snapshot() do
      %{meta: %{source_generated_at: at}} -> %{source_generated_at: at}
      _ -> nil
    end
  end

  defp age_label(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} ->
        "#{Calendar.strftime(at, "%Y-%m-%d")} (#{days_since(at)}d)"

      _ ->
        "unknown"
    end
  end

  defp days_since(at) do
    DateTime.diff(DateTime.utc_now(), at, :second) |> div(86_400) |> max(0)
  end

  @doc """
  The model's context window in tokens, resolved from the catalog.

    * `{:ok, tokens}` — the catalog is loaded and knows the model;
    * `:loading` — the catalog is still loading (a provisional answer is
      the caller's job; re-resolve after `{:catalog, :updated}`);
    * `:unknown` — loaded, but the model is absent (a cloud model not in
      the catalog, or `nil`).

  Lock-free: never queues behind the warm.
  """
  @spec context_window(String.t() | nil) :: {:ok, pos_integer()} | :loading | :unknown
  def context_window(nil), do: :unknown

  def context_window(spec) when is_binary(spec) do
    if ready?() do
      case LLMDB.model(spec) do
        {:ok, model} -> window_of(model)
        _ -> :unknown
      end
    else
      :loading
    end
  end

  @doc """
  Subscribes the caller to `{:catalog, :updated}`, sent once when the
  catalog (re)loads. When it is already loaded the message is sent
  immediately (the caller re-resolves), so a subscriber never has to race
  the load. Duplicate deliveries are harmless: the consumer re-resolves
  idempotently.

  A failed refresh is published as `{:catalog, {:failed, reason}}` instead
  (ADR 039 amendment 2026-10-18 (2)): the load on disk is untouched by a
  failed refresh, so no window moved and nothing needs re-resolving — but
  the human who asked for the refresh needs the reason, and so does the log.

  A FORCED refresh that finds the copy current publishes `{:catalog,
  :unchanged}`: "nothing to do" is an outcome, and a caller that said
  "refreshing…" must hear it. The timer's own no-ops stay silent — "no
  news" once a day is noise.
  """
  @spec subscribe() :: :ok
  def subscribe do
    # Unregister first, like `Session.subscribe/1`: this key is `:duplicate`, so
    # a caller that (re)subscribes — the TUI re-mounting on a session switch —
    # would otherwise hold TWO entries and get every notification twice.
    _ = Registry.unregister(@registry, @key)
    _ = Registry.register(@registry, @key, nil)
    if ready?(), do: send(self(), {:catalog, :updated})
    :ok
  end

  @doc """
  Refreshes the catalog copy now, in this process, and reloads from it.

  `:started` means the refresh was queued, not that it finished: the fetch is
  a ~11 MB download, and the caller (the TUI) must not block on it. The
  outcome is published to subscribers — `{:catalog, :updated}` when a new copy
  was written and loaded, `{:catalog, {:failed, reason}}` when it was not,
  `{:catalog, :unchanged}` when the copy was already current (a timer tick
  that finds nothing due publishes nothing at all).
  """
  @spec refresh() :: :started
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
    :started
  end

  @impl true
  def init(_opts), do: {:ok, %{timer: nil, armed?: false}, {:continue, :warm}}

  @impl true
  def handle_continue(:warm, state) do
    load()
    notify()
    {:noreply, arm(state)}
  end

  # The daily check (ADR 039 amendment 2026-10-18 (2)). `Refresh.run/1` decides
  # whether anything is due; when it is, `load/0` republishes the catalog and
  # subscribers re-resolve. A failure is reported, never fatal: the catalog on
  # disk is still the one that loaded.
  @impl true
  def handle_info(:refresh, state) do
    # A timer armed under an OLD interval must not fire after the policy
    # says `:never` — the interval is read at FIRE time, like every other
    # scheduled decision. Found live in the suite: a test armed 300ms, set
    # `:never`, and the stale tick ran a refresh against the next test's
    # failing transport, logging a 503 into an unrelated test.
    if Refresh.interval_ms() == :never do
      {:noreply, %{state | timer: nil, armed?: false}}
    else
      {:noreply, attempt(state, force: false)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, attempt(state, force: true)}
  end

  # The timer does not force: a copy the human refreshed by hand two hours
  # before the tick is younger than the interval, `Refresh.due?/2` says so, and
  # the tick costs a `File.stat/1` instead of an 11 MB download for a cut we
  # already have. The verb (`/catalog`) does force: a human who typed the
  # command wants the copy updated now, not the policy re-explained to them.
  defp attempt(state, opts) do
    # Whatever timer was pending is spent by the message that got here (or
    # belongs to a refresh the verb pre-empted): cancel it, so "one live timer"
    # stays true no matter how the attempt was triggered.
    if state.timer, do: Process.cancel_timer(state.timer)
    state = %{state | timer: nil}

    case Refresh.run(opts) do
      {:ok, :updated} ->
        load()
        notify()
        arm(state)

      {:ok, :unchanged} ->
        # A forced refresh (`/catalog`) that found the copy current is an
        # outcome, not silence: the human asked and the TUI said "refreshing
        # the model catalog…" — without this it never hears the end. The
        # timer's own no-ops stay silent; "no news" once a day is noise.
        if opts[:force], do: notify_unchanged()
        arm(state)

      {:ok, :skipped} ->
        arm(state)

      {:error, reason} ->
        Logger.warning("model catalog refresh failed: #{Refresh.describe(reason)}")
        notify_failed(reason)
        arm(state)
    end
  end

  # The timer is armed from ONE place, after every attempt: a failure must not
  # leave the catalog without a next check, and the ref is kept so a refresh that
  # arrives first cancels it instead of stacking a second one.
  defp arm(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    case Refresh.interval_ms() do
      :never ->
        %{state | timer: nil, armed?: false}

      ms ->
        delay = if state.armed?, do: ms, else: min(ms, Refresh.first_check_ms())
        %{state | timer: Process.send_after(self(), :refresh, delay), armed?: true}
    end
  end

  # The one loader. A refresh calls the same path. The artifact is tried FIRST
  # and the packaged snapshot second, with the reason logged: a copy that does
  # not load would otherwise leave llm_db's store empty, and the next read
  # would pay llm_db's own lazy load — the blocking load ADR 039 exists to get
  # off the mount path. A load failure is logged, not fatal: an empty catalog
  # just means every window falls back to the configured/default value.
  defp load do
    case load_source(Refresh.source(Refresh.artifact_path())) do
      :ok -> :ok
      :error -> load_source(:packaged)
    end
  end

  defp load_source(artifact = {:file, _path}) do
    case LLMDB.load(snapshot_source: artifact) do
      {:ok, _snapshot} ->
        Logger.debug("model catalog loaded from #{inspect(artifact)}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "model catalog: #{Refresh.describe(reason)} — falling back to the packaged snapshot"
        )

        :error
    end
  rescue
    e ->
      Logger.warning("model catalog load crashed: #{Exception.message(e)}")
      :error
  end

  defp load_source(:packaged) do
    case LLMDB.load(snapshot_source: :packaged) do
      {:ok, _snapshot} ->
        Logger.debug("model catalog loaded from the packaged snapshot")
        :ok

      {:error, reason} ->
        Logger.warning("packaged model catalog load failed: #{Refresh.describe(reason)}")
        :error
    end
  rescue
    e ->
      Logger.warning("packaged model catalog load crashed: #{Exception.message(e)}")
      :error
  end

  defp notify do
    Registry.dispatch(@registry, @key, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:catalog, :updated})
    end)
  end

  defp notify_failed(reason) do
    Registry.dispatch(@registry, @key, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:catalog, {:failed, reason}})
    end)
  end

  defp notify_unchanged do
    Registry.dispatch(@registry, @key, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:catalog, :unchanged})
    end)
  end

  # llm_db's limits shape has moved across versions; read a struct or a
  # plain map, atom or string keys, and accept :context or :context_length.
  # A window we cannot read is simply unknown.
  defp window_of(%{limits: limits}) when is_map(limits), do: window_of_limits(limits)
  defp window_of(_), do: :unknown

  defp window_of_limits(limits) do
    case limits[:context] || limits["context"] || limits[:context_length] ||
           limits["context_length"] do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> :unknown
    end
  end
end
