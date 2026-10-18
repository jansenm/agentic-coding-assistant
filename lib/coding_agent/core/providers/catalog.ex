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

  This process owns the catalog LIFECYCLE (warm now, refresh later — a
  timer is deliberately not wired yet) and is the single access point for
  our code: nobody calls `LLMDB` directly. Reads are lock-free (they read
  llm_db's `:persistent_term` snapshot) and never queue behind the warm,
  so a mount that races the load gets `:loading` and falls back instead of
  blocking. A refresh (future `Process.send_after`) would call
  `LLMDB.load/1` again and re-notify subscribers; llm_db swaps the
  snapshot atomically by digest, so readers keep seeing a consistent one.
  """

  use GenServer

  require Logger

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
  """
  @spec subscribe() :: :ok
  def subscribe do
    _ = Registry.register(@registry, @key, nil)
    if ready?(), do: send(self(), {:catalog, :updated})
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :warm}}

  @impl true
  def handle_continue(:warm, state) do
    load()
    notify()
    {:noreply, state}
  end

  # The one loader. A refresh (future timer) calls the same path. A load
  # failure is logged, not fatal: an empty catalog just means every window
  # falls back to the configured/default value.
  defp load do
    case LLMDB.load() do
      {:ok, _snapshot} -> Logger.debug("model catalog loaded")
      {:error, reason} -> Logger.warning("model catalog load failed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("model catalog load crashed: #{Exception.message(e)}")
  end

  defp notify do
    Registry.dispatch(@registry, @key, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:catalog, :updated})
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
