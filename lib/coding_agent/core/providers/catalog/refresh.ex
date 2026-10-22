defmodule CodingAgent.Core.Providers.Catalog.Refresh do
  @moduledoc """
  The one artifact the catalog reads that we own: a locally re-cut copy of
  llm_db's newest published snapshot (ADR 039, amendment 2026-10-18 (2)).

  llm_db ships a **packaged** snapshot, cut on its release cadence, and the
  pin in `mix.exs` (`{:req_llm, "~> 1.21"}` constrains `llm_db` to
  `~> 2026.8.4`) fixes which snapshot that is. Measured 2026-10-18: the
  packaged file is dated 2026-08-23, 56 days behind, and a cloud model
  released since — `ollama_cloud:deepseek-v4.1-flash` — is simply absent
  from it, so its context window falls back to a 500k guess (review N106
  dates that guess in the sidebar; this module is what makes the date
  move).

  **Why re-cut instead of pointing llm_db at the feed.** The newest
  published document does not load on the installed pin, and not because
  it is malformed. The reader's vocabulary is compile-time generated:
  `LLMDB.Generated.ProviderRegistry` builds the provider atoms from the
  packaged file when llm_db is compiled, and `ValidModalities` freezes the
  modality atoms the same way. Measured on the current release doc
  (11 330 065 B, 237 providers):

    * `LLMDB.Loader.load(snapshot_source: {:file, doc})` →
      `{:invalid_snapshot_item, :provider, {:unknown_provider_id, "wallaby"}}`
      — 42 of the 237 provider ids are newer than the pin, and one unknown
      id fails the WHOLE document;
    * trimming to the 195 registry-known providers (10 177 235 B, 89.8 %)
      fails deeper: `{:invalid_snapshot_item, :model,
      {:unknown_modality, "decisions"}}` — 27 entries in `azure`,
      `openrouter`, `cloudflare_workers_ai`.

  So the release document is an **input** to this module, never the
  artifact. The artifact is the packaged document — every provider the
  installed pin knows, byte-identical to what the app loads today — with
  the *configured* providers' entries swapped for the release's cut,
  `generated_at` taken from the release, and `snapshot_id` recomputed:

    measured — 8 356 127 B (packaged 8 347 265 B), 197 providers,
    `Snapshot.read/2` `:ok`, loads in ~2.5 s cold, and answers
    `ollama_cloud:deepseek-v4.1-flash → {:ok, 1048576}` where the packaged
    cut answers `:unknown`.

  **Why only the configured providers.** Swapping every registry-known,
  modality-clean provider was measured too — 9 956 183 B, ~3.2 s — for
  specifications no `[providers.*]` table names, i.e. ~1.6 MB and ~0.7 s
  of catalog the app has no way to reach by name. The conservative cut does
  not *shrink* the catalog: every provider the packaged file carries is
  still there, and the model menu's catalog half still lists them; only the
  configured ones get fresher. A configured provider the release does not
  carry (`hostyourai`, `ollama`) keeps its packaged entry and its fallback
  window.

  **Why verify by loading the file, not by reading it.** `Snapshot.read/2`
  is not evidence: the raw release document passes it (parse, id check,
  migrate, validate) and still fails the load pipeline above. The only
  check that matches what the app will do is the app's own call —
  `LLMDB.Loader.load/1`, the load pipeline *without* the store write
  (verified: the store stays `nil`). So a refresh writes a temp file, loads
  **that file** through `LLMDB.Loader.load/1`, and only on `{:ok, _}`
  renames it into place. The rename is atomic, so a reader never sees a
  half-written artifact.

  **Why the temp file carries the pid.** `Config.state_dir/0` is shared by
  every worktree of this repository (`~/.local/state/coding_agent`), and a
  repository with two checkouts routinely has two of them running at once —
  the same reason `Session.Store` serialises per store path.
  """

  require Logger

  alias CodingAgent.Core.{Config, Providers, UserConfig}
  alias LLMDB.Snapshot
  alias LLMDB.Snapshot.ReleaseStore

  # How often the CHECK runs (ADR 039: "once every 24h"), not how old the
  # data is allowed to be: the release cadence is roughly weekly, so a copy
  # a day old is usually already the newest cut, and the check is a
  # `File.stat/1` plus a no-op.
  @interval_ms 24 * 60 * 60 * 1000

  @artifact "catalog.json"
  @cache_dir "catalog-cache"
  # One release document per distinct cut, ~11 MB each. Keep the newest two:
  # one to serve the current refresh, one to compare against when a new cut
  # lands. Left alone this grows ~11 MB per release forever.
  @retained 2

  @typedoc """
  What one merge did: which configured providers were replaced, and for the
  ones that were not, why. `:swapped` is in the order the providers were
  given, so the report reads like the config.
  """
  @type report :: %{
          swapped: [String.t()],
          skipped: %{String.t() => term()}
        }

  @doc """
  The artifact: the catalog copy this application owns and rewrites, beside
  `store.db` in `Config.state_dir/0`.

  State, not configuration (`~/.config/coding-agent`) and not user data
  (`~/.local/share/coding-agent`): it is derived, the app regenerates it
  whenever it is missing or stale, and it may be deleted without losing
  anything the user typed.
  """
  @spec artifact_path() :: String.t()
  def artifact_path do
    Keyword.get(config(), :artifact, Path.join(Config.state_dir(), @artifact))
  end

  @doc false
  # The document a refresh merges INTO: llm_db's packaged snapshot, i.e. exactly
  # what the app loads today. Overridable only so a test can drive the whole
  # lifecycle (warm, timer, `/catalog`) on a 600-byte document instead of an 8 MB
  # one — the same `:catalog_refresh` seam `artifact_path/0` reads; nothing in the
  # app sets it.
  @spec base_path() :: String.t()
  def base_path, do: Keyword.get(config(), :base, Snapshot.packaged_path())

  @doc """
  Which source a caller should load, given the artifact path: the copy when
  there is one, llm_db's packaged snapshot otherwise.

  This is the cold-start decision (ADR 039 amendment 2026-10-18 (2)), and it is
  `File.exists?/1` rather than a read on purpose: a copy that is present but
  unloadable must be TRIED, so the caller can report which file failed and
  fall back to the pin with the reason; treating "not readable" as "absent"
  here would hide the failure. `due?/2` is what notices that state and
  rebuilds.
  """
  @spec source(String.t()) :: {:file, String.t()} | :packaged
  def source(artifact) do
    if File.exists?(artifact), do: {:file, artifact}, else: :packaged
  end

  @doc """
  Whether the artifact needs to be (re)built: missing, not a regular file,
  older than the daily check, or **unreadable**.

  The last case matters and is not a detail: the warm falls back to the
  packaged snapshot when the artifact will not load, so a truncated or
  half-written copy is invisible at runtime — every window quietly answers from
  the pin's cut — and nothing else would ever notice. `artifact_cut/1` is the
  same read the "already have this cut" check does, so this costs one read of a
  few hundred KB to 8 MB per check (a daily tick, or the verb).

  `now` is a parameter so a test can move the clock instead of the file.
  """
  @spec due?(String.t(), DateTime.t()) :: boolean()
  def due?(artifact, now) do
    case File.stat(artifact, time: :posix) do
      {:ok, %{type: :regular, mtime: mtime}} ->
        DateTime.diff(now, DateTime.from_unix!(mtime)) >= div(@interval_ms, 1000) or
          artifact_cut(artifact) == nil

      {:ok, _other_type} ->
        true

      {:error, _reason} ->
        true
    end
  end

  @doc """
  Brings the artifact up to date, in the caller's process. `Catalog` is the
  only caller in the app, so a manual refresh queues behind an automatic one
  instead of racing it.

  Options:

    * `:force` — refresh even when `due?/2` says no. The timer does not set
      it; the `/catalog` verb does, because a human who types the command
      wants the copy updated, not a policy decision re-explained to them.
    * `:artifact`, `:base`, `:now` — a different artifact path, a tiny packaged
      document, a moved clock.
    * `:providers` and `:fetch` — the transport seams a test drives, so the
      pipeline runs on local documents and never touches the network. Their
      defaults are the configured ones (`:catalog_refresh` in the app env; the
      release host when unconfigured).

  Returns:

    * `{:ok, :updated}` — a new artifact was written and verified;
    * `{:ok, :unchanged}` — nothing to do: the release carries no provider
      newer than what we already have, or the artifact already carries this
      cut (so no write, no notify, no subscriber churn);
    * `{:ok, :skipped}` — not due;
    * `{:error, reason}` — the refresh did not happen and the old artifact
      (or the packaged file, if there is none) is still what loads. The
      reason is for the caller to report; `describe/1` turns it into prose.
  """
  @spec run(keyword()) :: {:ok, :updated | :unchanged | :skipped} | {:error, term()}
  def run(opts \\ []) do
    artifact = Keyword.get_lazy(opts, :artifact, &artifact_path/0)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if Keyword.get(opts, :force, false) or due?(artifact, now) do
      refresh(artifact, opts)
    else
      {:ok, :skipped}
    end
  rescue
    e -> {:error, {:crashed, Exception.message(e)}}
  end

  @doc """
  The merged document plus what happened to each provider: the packaged
  `base` with the entries of `providers` replaced by the `release`'s cut,
  re-identified and dated by that release — but only when at least one entry
  was actually swapped, so a document carrying no new data never wears a
  newer date.

  Pure, so the merge rules are testable without a network or a file. A
  provider is swapped only when the release carries it, the packaged base
  has it, the compile-time registry knows its id, and every modality its
  models name is one the installed reader can digest. Each of those is
  measured as a whole-document failure, so they are checked per provider and
  the refusals are reported rather than swallowed.
  """
  @spec build(map(), map(), [String.t()]) :: {map(), report()}
  def build(base, release, providers) do
    {entries, report} =
      Enum.reduce(providers, {base["providers"], %{swapped: [], skipped: %{}}}, fn id, {acc, r} ->
        case entry(id, base, release) do
          {:ok, entry} -> {Map.put(acc, id, entry), %{r | swapped: [id | r.swapped]}}
          {:skip, reason} -> {acc, %{r | skipped: Map.put(r.skipped, id, reason)}}
        end
      end)

    report = %{report | swapped: Enum.reverse(report.swapped)}

    document =
      base
      |> Map.put("providers", entries)
      |> Map.put(
        "generated_at",
        if(report.swapped == [], do: base["generated_at"], else: release["generated_at"])
      )
      |> re_id()

    {document, report}
  end

  defp entry(id, base, release) do
    cond do
      not Map.has_key?(release["providers"] || %{}, id) ->
        {:skip, :absent_from_release}

      not Map.has_key?(base["providers"] || %{}, id) ->
        {:skip, :absent_from_packaged}

      not known_provider?(id) ->
        {:skip, :unknown_to_installed_reader}

      true ->
        provider = release["providers"][id]

        case unknown_modalities(provider) do
          [] -> {:ok, provider}
          unknown -> {:skip, {:unknown_modalities, unknown}}
        end
    end
  end

  # A provider id the compile-time registry does not know cannot be
  # deserialised at all: `Loader.provider_atom/1` answers
  # `{:error, {:unknown_provider_id, id}}` and the WHOLE load fails. The
  # check goes through `ProviderRegistry.fetch/1`, never `String.to_atom/1`
  # — that module exists precisely so untrusted JSON cannot grow the atom
  # table.
  defp known_provider?(id) when is_binary(id) do
    match?({:ok, _}, LLMDB.Generated.ProviderRegistry.fetch(id))
  end

  defp known_provider?(_id), do: false

  # Same story for the modality vocabulary: `ValidModalities` is the frozen
  # list, `Loader.deserialize_modality_list/1` halts on anything else, and
  # the failure takes the whole document down with it.
  defp unknown_modalities(provider) do
    provider
    |> Map.get("models", %{})
    |> Enum.flat_map(fn {_id, model} -> modalities_of(model) end)
    |> Enum.uniq()
    |> Enum.reject(&known_modality?/1)
    |> Enum.sort()
  end

  defp modalities_of(model) when is_map(model) do
    case Map.get(model, "modalities") do
      %{} = modalities ->
        Enum.flat_map(["input", "output"], fn key -> Map.get(modalities, key) || [] end)

      _other ->
        []
    end
  end

  defp modalities_of(_model), do: []

  defp known_modality?(name) when is_binary(name) do
    match?({:ok, _}, LLMDB.Generated.ValidModalities.fetch(name))
  end

  defp known_modality?(_name), do: false

  # `snapshot_id` is a content address over the canonical digest of the
  # document, so editing providers invalidates the base's — and it MUST be
  # recomputed: integrity is `:strict` by default, and a stale id is a file
  # that never loads. `Snapshot.snapshot_id/1` is llm_db's own digest
  # (sparse-aware, exclusion-aware); hand-rolling it here would drift from
  # the reader it has to satisfy.
  defp re_id(document) do
    document
    |> Map.delete("snapshot_id")
    |> then(&Map.put(&1, "snapshot_id", Snapshot.snapshot_id(&1)))
  end

  defp refresh(artifact, opts) do
    base_path = Keyword.get(opts, :base, base_path())
    providers = Keyword.get_lazy(opts, :providers, &configured_providers/0)
    # `Keyword.get/3`, NOT `get_lazy/3`: the default here is the fetcher FUNCTION
    # itself, and `get_lazy` would call it at this point instead — handing
    # `fetch` an already-fetched document. (Found live: the download ran, then
    # the merge tried to call `{:ok, %{snapshot: …}}` as a function.)
    fetch = Keyword.get(opts, :fetch, &fetch_release/0)

    with {:ok, base} <- Snapshot.read(base_path),
         {:ok, fetched} <- fetch.(),
         {:ok, release} <- release_document(fetched) do
      {document, report} = build(base, release, providers)
      log_report(report)

      cond do
        report.swapped == [] -> {:ok, :unchanged}
        document["generated_at"] == artifact_cut(artifact) -> {:ok, :unchanged}
        true -> publish(artifact, document)
      end
    end
  end

  # The fetch may hand back llm_db's release-store envelope
  # (`%{snapshot: doc, snapshot_id: id, path: path}`) or the document itself;
  # a test stub is free to do either. Anything else is reported as what it
  # is, instead of failing later inside the merge on a key lookup.
  defp release_document(%{snapshot: %{} = document}), do: {:ok, document}
  defp release_document(%{"providers" => _providers} = document), do: {:ok, document}
  defp release_document(other), do: {:error, {:unexpected_release_document, other}}

  defp publish(artifact, document) do
    tmp = tmp_path(artifact)

    try do
      Snapshot.write!(tmp, document)

      # Verify through the SAME call the app makes, on the file that is about
      # to become the artifact: `Snapshot.read/2` alone would not do (see the
      # moduledoc) — it accepts documents the loader then refuses.
      case LLMDB.Loader.load(snapshot_source: {:file, tmp}) do
        {:ok, _snapshot} ->
          File.rename!(tmp, artifact)
          {:ok, :updated}

        {:error, reason} ->
          {:error, {:verify_failed, reason}}
      end
    after
      # On success the rename moved it, so this is a no-op; on failure it is
      # the cleanup.
      File.rm(tmp)
    end
  end

  # Two worktrees of this repo share `state_dir()`, so the temp name carries
  # the OS pid: without it one refresh could verify the other's leftovers.
  defp tmp_path(artifact), do: "#{artifact}.#{System.pid()}.tmp"

  # The cut the artifact already carries, for the "nothing new" case: a
  # release whose `generated_at` we already have must not be re-written and
  # re-notified to every session once a day. A missing or corrupt artifact
  # reads as `nil` — and `due?/2` treats that as due, so an unreadable copy is
  # rebuilt instead of serving silently from the packaged fallback forever.
  defp artifact_cut(artifact) do
    case Snapshot.read(artifact) do
      {:ok, document} -> document["generated_at"]
      {:error, _reason} -> nil
    end
  end

  # The configured providers, from the process-wide config layers. `Catalog`
  # is one process for the whole app, started before any session, so it has
  # no scope root to read a project layer with: a `[providers.*]` table that
  # exists only in a repository's `.coding-agent/config.toml` does not join
  # this list. `Providers.list/1` is the same reader the model menu uses, so
  # the artifact covers exactly the names the app can reach by name.
  #
  # `:providers` in the app env replaces the lookup outright — the seam the
  # suite drives the whole `Catalog` path through, without a network and
  # without touching the user's XDG config, the same way `:fetch` does.
  defp configured_providers do
    case Keyword.get(config(), :providers) do
      nil ->
        case UserConfig.load_safe(nil) do
          {:ok, %{config: config}} ->
            Providers.list(config)

          {:error, message} ->
            Logger.warning("model catalog: cannot read the provider list: #{message}")
            []
        end

      providers when is_list(providers) ->
        providers
    end
  end

  @doc """
  Fetches llm_db's newest published snapshot into our cache directory:
  llm_db's own release store (default repo `agentjido/llmdb`, keyless, no
  token), the transport `mix llm_db.snapshot.fetch` uses.

  Its cache is content-addressed — the file is named after the snapshot id
  and read back through `Snapshot.read/2` — so a torn or partial download
  reads as a cache miss rather than as a corrupt catalog.
  """
  @spec fetch_release() :: {:ok, term()} | {:error, term()}
  def fetch_release do
    case Keyword.get(config(), :fetch) do
      {module, function, args} -> apply(module, function, args)
      fun when is_function(fun, 0) -> fun.()
      # No transport configured: the real one. The test run configures one
      # (config/test.exs) so the suite never reaches the network.
      nil -> release_store_fetch()
      other -> {:error, {:invalid_fetch, other}}
    end
  end

  defp release_store_fetch do
    result = ReleaseStore.fetch_snapshot(:latest, %{cache_dir: cache_dir()})
    prune_cache()
    result
  end

  @doc """
  The release store's cache directory, under the state directory (the
  default `tmp/llm_db/snapshot_cache` is relative to the current working
  directory, which is a project the app does not own).
  """
  @spec cache_dir() :: String.t()
  def cache_dir, do: Path.join(Config.state_dir(), @cache_dir)

  defp prune_cache do
    dir = Path.join(cache_dir(), "snapshots")

    with {:ok, names} <- File.ls(dir) do
      names
      |> Enum.map(&{&1, mtime(Path.join(dir, &1))})
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.drop(@retained)
      |> Enum.each(fn {name, _mtime} -> File.rm(Path.join(dir, name)) end)
    end

    :ok
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _reason} -> 0
    end
  end

  defp log_report(%{swapped: [], skipped: skipped}) do
    Logger.debug("model catalog: no provider to swap (#{inspect(Map.keys(skipped))})")
  end

  defp log_report(%{swapped: swapped, skipped: skipped}) do
    kept = if skipped == %{}, do: "", else: ", kept #{inspect(Map.keys(skipped))}"
    Logger.debug("model catalog: swapped #{inspect(swapped)}#{kept}")
  end

  @doc """
  A one-line, human-readable form of a refresh failure, for the log and the
  composer note. The reasons come from llm_db's transport and loader, whose
  own `inspect` is a nested tuple or a whole response body; this names what
  happened, so a human reading the note can decide what to do about it.
  """
  @spec describe(term()) :: String.t()
  def describe(reason) do
    case reason do
      :not_found ->
        "the release index lists no snapshot"

      {:http_status, status, _body} ->
        "the release host answered HTTP #{status}"

      {:verify_failed, inner} ->
        "the refreshed copy would not load: #{describe(inner)}"

      {:unexpected_release_document, other} ->
        "the release host returned #{shape(other)}, not a snapshot document"

      {:crashed, message} ->
        message

      %{__struct__: struct} ->
        "#{inspect(struct)}: #{Exception.message(reason)}"

      other ->
        inspect(other)
    end
  end

  defp shape(%{} = map), do: "a map with #{inspect(Map.keys(map) |> Enum.sort())}"
  defp shape(list) when is_list(list), do: "a list"
  defp shape(other), do: inspect(other)

  @doc false
  # How often the catalog checks, in milliseconds — `:never` disables the timer
  # (the test run: the suite must not download 11 MB). ADR 039's "once every
  # 24h" is this value, not the age of the data: the release cadence is
  # roughly weekly, so a copy a day old is usually already the newest cut and
  # the check is a `File.stat/1` plus a no-op.
  @spec interval_ms() :: pos_integer() | :never
  def interval_ms, do: Keyword.get(config(), :interval_ms, @interval_ms)

  @doc false
  # The delay before the FIRST check of a run. Short, so a copy that went stale
  # while the app was not running is replaced within the same session instead
  # of after a day — but not zero: a mount racing the boot must be finished, or
  # the refresh would compete with the one path this process exists to keep
  # free.
  @spec first_check_ms() :: pos_integer()
  def first_check_ms do
    Keyword.get(config(), :first_check_ms, 5_000)
  end

  defp config, do: Application.get_env(:coding_agent, :catalog_refresh, [])
end
