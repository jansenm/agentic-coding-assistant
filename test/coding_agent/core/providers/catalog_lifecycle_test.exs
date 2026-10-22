defmodule CodingAgent.Core.Providers.CatalogLifecycleTest do
  @moduledoc """
  The catalog's lifecycle around the refresh (ADR 039 amendment 2026-10-18
  (2)): what the automatic check and the `/catalog` verb do to the running
  catalog, and which source the warm picks.

  The RUNNING `CodingAgent.Core.Providers.Catalog` (started with the app) is
  driven here, so the assertions are about the process the app actually runs.
  Nothing here reaches the network, and nothing here reads or writes the user's
  state or config:

    * `:catalog_refresh` points the artifact, the packaged base and the
      transport at this test's temp dir and at local documents
      (`CodingAgent.TestCatalogFetch`), so the release host is never asked.

  Two things about the mechanics, both learned the hard way:

    * the catalog is a process-wide SINGLETON over a process-wide store
      (`:persistent_term`), so each test states the starting point it needs
      (``reset_to_packaged/0``) and hands the store back on the way out. A test
      that restarted the child instead made an unrelated sync test see a cold
      catalog — the store is shared with every other file in the suite;
    * the timer is OFF for the whole run (`config/test.exs`:
      `interval_ms: :never`, so no run downloads 11 MB). A test that wants the
      automatic path sends the tick the timer would send (``tick/0``) — the same
      message, the same ``handle_info(:refresh, …)`` clause, the same
      ``force: false`` — and puts `:never` back before it ends, so the arm that
      followed its tick cannot fire during a later test.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Providers.Catalog

  @release_cut "2026-10-17T00:00:00Z"

  setup do
    previous_refresh = Application.get_env(:coding_agent, :catalog_refresh)
    previous_response = CodingAgent.TestCatalogFetch.response()

    dir = Path.join(System.tmp_dir!(), "catalog-lifecycle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # The paths come from the config, not from `Config.state_dir/0`: they must
    # not depend on which directory the suite's other files pointed XDG at.
    artifact = Path.join(dir, "catalog.json")

    configure(
      artifact: artifact,
      base: write!(dir, "base.json", base_document()),
      providers: ["openai"],
      fetch: {CodingAgent.TestCatalogFetch, :call, []},
      interval_ms: :never
    )

    CodingAgent.TestCatalogFetch.respond(release_document())

    # Known starting point: the store is process-wide, so a previous test's
    # artifact would otherwise still be what this one reads. The packaged
    # snapshot is exactly what a fresh boot sees.
    reset_to_packaged()

    on_exit(fn ->
      configure(interval_ms: :never)
      reset_to_packaged()
      Application.put_env(:coding_agent, :catalog_refresh, previous_refresh)
      CodingAgent.TestCatalogFetch.restore(previous_response)
      File.rm_rf!(dir)
    end)

    %{dir: dir, artifact: artifact}
  end

  # -- helpers ----------------------------------------------------------------

  defp configure(values) do
    current = Application.get_env(:coding_agent, :catalog_refresh, [])
    Application.put_env(:coding_agent, :catalog_refresh, Keyword.merge(current, values))
  end

  defp reset_to_packaged do
    {:ok, _snapshot} = LLMDB.load(snapshot_source: :packaged)
    :ok
  end

  defp write!(dir, name, document) do
    path = Path.join(dir, name)
    LLMDB.Snapshot.write!(path, document)
    path
  end

  defp base_document do
    document("2026-08-01T00:00:00Z", %{"openai" => provider("openai", %{"gpt-4o" => 128_000})})
  end

  # the release cut adds a model the base's copy does not have
  defp release_document do
    document(@release_cut, %{
      "openai" => provider("openai", %{"gpt-4o" => 128_000, "gpt-9" => 424_242})
    })
  end

  defp document(generated_at, providers) do
    %{
      "version" => 2,
      "schema_version" => 1,
      "generated_at" => generated_at,
      "providers" => providers
    }
    |> then(&Map.put(&1, "snapshot_id", LLMDB.Snapshot.snapshot_id(&1)))
  end

  defp provider(id, models) do
    %{
      "id" => id,
      "name" => id,
      "models" =>
        Map.new(models, fn {model_id, context} ->
          {model_id,
           %{
             "id" => model_id,
             "provider" => id,
             "name" => model_id,
             "limits" => %{"context" => context},
             "modalities" => %{"input" => ["text"], "output" => ["text"]}
           }}
        end)
    }
  end

  defp packaged_cut do
    {:ok, document} = LLMDB.Snapshot.read(LLMDB.Snapshot.packaged_path())
    document["generated_at"]
  end

  defp loaded_cut do
    case LLMDB.snapshot() do
      %{meta: %{source_generated_at: at}} -> at
      _ -> nil
    end
  end

  # `Catalog.refresh/0` is a cast and the refresh (fetch, merge, verify, load)
  # runs in the catalog process: wait for the OUTCOME, not for a sleep.
  defp wait_for(fun, label, deadline \\ System.monotonic_time(:millisecond) + 15_000) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("timed out waiting for #{label}")
      true -> Process.sleep(10) && wait_for(fun, label, deadline)
    end
  end

  # The tick the timer would send, sent by hand (the suite keeps the timer off).
  defp tick do
    send(Process.whereis(Catalog), :refresh)
    :ok
  end

  # -- the manual refresh (the /catalog verb) ---------------------------------

  test "a refresh re-loads the catalog, and the window a model only the new cut knows follows",
       %{artifact: artifact, dir: dir} do
    # the setup put the store back on the packaged snapshot
    assert loaded_cut() == packaged_cut()
    assert :unknown = Catalog.context_window("openai:gpt-9")

    assert :started = Catalog.refresh()
    wait_for(fn -> loaded_cut() == @release_cut end, "the refreshed catalog to load")

    # the copy is on disk, verified, and the window the app reads moved
    assert File.exists?(artifact)
    assert Catalog.snapshot_age() =~ "2026-10-17"
    assert {:ok, 424_242} = Catalog.context_window("openai:gpt-9")
    assert {:ok, 128_000} = Catalog.context_window("openai:gpt-4o")

    # the temp file that was verified is gone: renamed into place, not left
    assert File.ls!(dir) |> Enum.sort() == ["base.json", "catalog.json"]
  end

  test "a refresh of the same cut rewrites nothing, and a failing one reports its reason",
       %{artifact: artifact} do
    assert :started = Catalog.refresh()
    wait_for(fn -> File.exists?(artifact) end, "the artifact to be written")
    mtime = File.stat!(artifact, time: :posix).mtime

    assert :started = Catalog.refresh()
    wait_for(fn -> loaded_cut() == @release_cut end, "the second refresh to land")
    assert File.stat!(artifact, time: :posix).mtime == mtime

    # now the transport fails: the catalog keeps serving what it has, and the
    # failure reaches a subscriber with its reason
    CodingAgent.TestCatalogFetch.respond({:error, {:http_status, 503, "down"}})
    assert :ok = Catalog.subscribe()
    assert_receive {:catalog, :updated}, 1_000

    assert :started = Catalog.refresh()
    assert_receive {:catalog, {:failed, {:http_status, 503, "down"}}}, 3_000
    assert Catalog.ready?()
    assert File.stat!(artifact, time: :posix).mtime == mtime
  end

  # -- the automatic check ----------------------------------------------------

  test "the daily check replaces a copy that will not load, and keeps checking",
       %{artifact: artifact, dir: dir} do
    File.write!(artifact, "not a snapshot")
    configure(interval_ms: 500)
    tick()

    assert :ok = Catalog.subscribe()

    # the artifact is the barrier that belongs to THIS test (the loaded cut is
    # process-wide, so another test's cut could be a false positive)
    wait_for(
      fn -> match?({:ok, _document}, LLMDB.Snapshot.read(artifact)) end,
      "the check to replace the copy"
    )

    assert {:ok, document} = LLMDB.Snapshot.read(artifact)
    assert document["generated_at"] == @release_cut
    # and the reload followed the write
    wait_for(fn -> loaded_cut() == @release_cut end, "the replaced copy to load")
    assert_receive {:catalog, :updated}, 2_000

    # the temp file was renamed, not left behind
    assert File.ls!(dir) |> Enum.sort() == ["base.json", "catalog.json"]

    # it re-armed (the arm reads the interval the test set), and `:never` now
    # stops the loop before this test ends
    configure(interval_ms: :never)
  end

  test "a failing automatic check reports the reason, keep its schedule and stays serving" do
    CodingAgent.TestCatalogFetch.respond({:error, {:http_status, 503, "down"}})
    configure(interval_ms: 300)
    tick()

    assert :ok = Catalog.subscribe()

    # the failure is published WITH its reason — the note in the composer needs
    # it — and the catalog keeps serving what it already has
    assert_receive {:catalog, {:failed, {:http_status, 503, "down"}}}, 3_000
    assert Catalog.ready?()

    # and it re-armed: with an interval configured the process holds a live
    # timer, which the failing attempt must not have dropped. (Asserting the
    # flag rather than waiting out a second tick: the suite's timer is off, and
    # a test that races the wall clock is the kind of test that flakes in a
    # loaded run.)
    assert :sys.get_state(Catalog).armed?

    # the second attempt takes the same path, so a transient outage is retried
    # rather than fatal
    tick()
    assert_receive {:catalog, {:failed, {:http_status, 503, "down"}}}, 3_000

    configure(interval_ms: :never)
  end
end
