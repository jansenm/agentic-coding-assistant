defmodule CodingAgent.Core.Providers.CatalogRefreshTest do
  @moduledoc """
  The refresh pipeline (ADR 039 amendment 2026-10-18 (2)): fetch, re-cut for
  the installed pin, verify, rename.

  Every test drives the pipeline with LOCAL documents through the
  parameterized entry points — a tiny packaged base, a tiny release
  document, a fetcher that returns it — so the suite never reaches the
  release host. `config/test.exs` disables the timer for the same reason
  (`interval_ms: :never`); the last test here locks that.

  The fixtures are hand-built rather than sliced out of the shipped document:
  the sizes are then part of what the test says (a 2-provider document is
  ~600 bytes and loads in milliseconds), and a fixture cannot silently change
  when llm_db's packaged snapshot moves. `test/coding_agent/core/providers/
  catalog_test.exs` covers the real snapshot.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Providers.Catalog.Refresh

  @release_cut "2026-10-16T04:13:00.936867Z"

  setup do
    dir = Path.join(System.tmp_dir!(), "catalog-refresh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, artifact: Path.join(dir, "catalog.json")}
  end

  # -- fixtures ---------------------------------------------------------------

  # A provider entry in llm_db's document shape (`"providers"` is a map keyed
  # by id, each entry holding a `"models"` map).
  defp provider(id, models) do
    %{
      "id" => id,
      "name" => String.capitalize(id),
      "models" =>
        Map.new(models, fn {model_id, context} -> {model_id, model(id, model_id, context)} end)
    }
  end

  defp model(
         provider_id,
         model_id,
         context,
         modalities \\ %{"input" => ["text"], "output" => ["text"]}
       ) do
    %{
      "id" => model_id,
      "provider" => provider_id,
      "name" => model_id,
      "limits" => %{"context" => context},
      "modalities" => modalities
    }
  end

  defp doc(generated_at, providers),
    do:
      re_id(%{
        "version" => 2,
        "schema_version" => 1,
        "generated_at" => generated_at,
        "providers" => providers
      })

  defp re_id(document) do
    document
    |> Map.delete("snapshot_id")
    |> Map.put("snapshot_id", LLMDB.Snapshot.snapshot_id(document))
  end

  # Two providers the installed registry knows (`openai`, `anthropic`), one of
  # them the "configured" one in most tests.
  defp base do
    doc("2026-08-01T00:00:00Z", %{
      "openai" => provider("openai", %{"gpt-4o" => 128_000}),
      "anthropic" => provider("anthropic", %{"claude-x" => 200_000})
    })
  end

  defp write!(dir, name, document) do
    path = Path.join(dir, name)
    LLMDB.Snapshot.write!(path, document)
    path
  end

  # The models of the snapshot a load produced, keyed provider-then-model —
  # read from the LOADED snapshot. `LLMDB.model/1` would read the process-wide
  # store instead and trigger llm_db's lazy packaged load behind our back.
  defp loaded_models(snapshot) do
    Map.new(snapshot.models, fn {provider, models} ->
      {provider, Map.new(models, &{&1.id, &1})}
    end)
  end

  defp load!(path) do
    assert {:ok, snapshot} = LLMDB.Loader.load(snapshot_source: {:file, path})
    snapshot
  end

  # A fetcher that answers llm_db's release-store envelope, like the real one.
  defp fetch(document),
    do: fn -> {:ok, %{snapshot: document, snapshot_id: document["snapshot_id"]}} end

  # -- due?/2 -----------------------------------------------------------------

  test "due?/2 is true for a missing artifact, false right after a write, true past the interval",
       %{dir: dir, artifact: artifact} do
    now = DateTime.utc_now()
    assert Refresh.due?(artifact, now)

    # a real, readable document just written: nothing to do
    LLMDB.Snapshot.write!(artifact, base())
    assert Refresh.due?(artifact, now) == false
    assert Refresh.due?(artifact, DateTime.add(now, 23, :hour)) == false
    assert Refresh.due?(artifact, DateTime.add(now, 24, :hour))
    assert Refresh.due?(artifact, DateTime.add(now, 90, :day))

    # an unreadable copy is NOT an artifact to serve: the warm falls back to the
    # packaged snapshot and would otherwise keep doing so forever, so this is
    # due however fresh it looks
    File.write!(artifact, "not a snapshot")
    assert Refresh.due?(artifact, now)

    # and neither is a path that is not a regular file
    File.mkdir_p!(Path.join(dir, "adir"))
    assert Refresh.due?(Path.join(dir, "adir"), now)
  end

  test "the warm tries the artifact first and the packaged snapshot second" do
    assert Refresh.source("/tmp/definitely-not-here-#{System.unique_integer()}") == :packaged
    assert Refresh.source(Refresh.artifact_path()) == :packaged

    path = Path.join(System.tmp_dir!(), "source-#{System.unique_integer([:positive])}.json")
    File.write!(path, "{}")
    on_exit(fn -> File.rm(path) end)

    assert Refresh.source(path) == {:file, path}

    # a path that is not a regular file is still TRIED, not silently skipped:
    # the caller reports which file failed and falls back with the reason, and
    # `due?/2` is what notices and rebuilds
    File.mkdir_p!(path <> ".dir")
    on_exit(fn -> File.rm_rf(path <> ".dir") end)
    assert Refresh.source(path <> ".dir") == {:file, path <> ".dir"}
  end

  test "the artifact lives under the state directory, beside the store" do
    assert Refresh.artifact_path() ==
             Path.join(CodingAgent.Core.Config.state_dir(), "catalog.json")

    assert Refresh.cache_dir() == Path.join(CodingAgent.Core.Config.state_dir(), "catalog-cache")
  end

  # -- build/3 ----------------------------------------------------------------

  test "build/3 swaps the named providers, keeps the rest, and dates the document from the release" do
    release =
      doc(@release_cut, %{
        "openai" => provider("openai", %{"gpt-4o" => 999_999, "gpt-5" => 400_000})
      })

    {document, report} = Refresh.build(base(), release, ["openai"])

    assert report.swapped == ["openai"]
    assert document["generated_at"] == @release_cut

    # the swapped entry is the release's: a new model AND a moved window
    models = document["providers"]["openai"]["models"]
    assert models["gpt-4o"]["limits"]["context"] == 999_999
    assert models["gpt-5"]["limits"]["context"] == 400_000

    # the unconfigured provider is untouched, at the base cut
    assert document["providers"]["anthropic"] == base()["providers"]["anthropic"]

    # and the id is recomputed: the base's id no longer describes the document,
    # which is fatal under the strict default integrity policy
    refute document["snapshot_id"] == base()["snapshot_id"]
    assert :ok = LLMDB.Snapshot.verify(document)
  end

  test "build/3 keeps the base date when nothing was swapped" do
    release = doc(@release_cut, %{"openai" => provider("openai", %{"gpt-4o" => 999_999})})

    {document, report} = Refresh.build(base(), release, ["unconfigured"])

    assert report.swapped == []
    assert report.skipped == %{"unconfigured" => :absent_from_release}
    assert document["generated_at"] == "2026-08-01T00:00:00Z"
  end

  # Each refusal is a whole-document failure measured against the real release
  # document: one unknown provider id fails the load ("wallaby" against the
  # installed registry), and one unknown modality fails it deeper
  # ("decisions" under azure/openrouter/cloudflare_workers_ai). Both are
  # therefore checked per provider, and neither may enter the artifact.
  test "build/3 refuses a provider the installed reader cannot digest, per provider" do
    unknown_id = %{"wallaby" => provider("wallaby", %{"hop" => 1})}

    unknown_modality = %{
      "anthropic" => %{
        provider("anthropic", %{})
        | "models" => %{
            "claude-x" =>
              model("anthropic", "claude-x", 1, %{"input" => ["text"], "output" => ["decisions"]})
          }
      }
    }

    release = doc(@release_cut, Map.merge(unknown_id, unknown_modality))
    {document, report} = Refresh.build(base(), release, ["openai", "anthropic", "wallaby"])

    assert report.swapped == []
    assert report.skipped["openai"] == :absent_from_release
    assert report.skipped["wallaby"] == :absent_from_packaged
    assert report.skipped["anthropic"] == {:unknown_modalities, ["decisions"]}

    # nothing leaked in — the document is still loadable
    refute Map.has_key?(document["providers"], "wallaby")

    assert document["providers"]["anthropic"]["models"]["claude-x"]["limits"]["context"] ==
             200_000
  end

  test "build/3 reports a provider the release has, the base does not, and one that is not configured" do
    # "openai" is in both; "groq" is in the release only; the caller also lists
    # a name from neither document
    release =
      doc(@release_cut, %{
        "openai" => provider("openai", %{"gpt-4o" => 1}),
        "groq" => provider("groq", %{"llama" => 2})
      })

    {_document, report} = Refresh.build(base(), release, ["openai", "groq", "nowhere"])

    assert report.swapped == ["openai"]
    assert report.skipped == %{"groq" => :absent_from_packaged, "nowhere" => :absent_from_release}
  end

  # A model whose own "provider" field names a provider the installed reader
  # does not know is the case that separates reading a document from loading
  # it: `Snapshot.read/2` passes it (the provider IDs of the DOCUMENT are all
  # fine), and `Loader.provider_atom/1` then fails on the model. This is not
  # hypothetical — the real release document fails exactly here for 42 newer
  # provider ids — and no merge-side check can see it, which is why the
  # verification step loads the file that is about to become the artifact.
  test "run/1 refuses a document that only fails the LOAD, and leaves the artifact alone",
       %{dir: dir, artifact: artifact} do
    base_path = write!(dir, "base.json", base())

    stray = %{
      "openai" => %{
        provider("openai", %{})
        | "models" => %{"gpt-4o" => model("no-such-provider-here", "gpt-4o", 128_000)}
      }
    }

    release = doc(@release_cut, stray)
    assert {:ok, _} = LLMDB.Snapshot.read(write!(dir, "release.json", release))

    assert {:error, {:verify_failed, reason}} =
             Refresh.run(
               artifact: artifact,
               base: base_path,
               providers: ["openai"],
               fetch: fetch(release)
             )

    assert {:invalid_snapshot_item, :model, {:unknown_provider_id, "no-such-provider-here"}} =
             reason

    # the artifact was never replaced, and the temp file is gone
    refute File.exists?(artifact)
    assert File.ls!(dir) |> Enum.sort() == ["base.json", "release.json"]
  end

  # -- run/1 ------------------------------------------------------------------

  test "run/1 writes, verifies and lands the artifact, and the model the old copy did not know answers",
       %{dir: dir, artifact: artifact} do
    base_path = write!(dir, "base.json", base())

    release =
      doc(@release_cut, %{
        "openai" => provider("openai", %{"gpt-4o" => 128_000, "gpt-5" => 400_000})
      })

    assert {:ok, :updated} =
             Refresh.run(
               artifact: artifact,
               base: base_path,
               providers: ["openai"],
               fetch: fetch(release)
             )

    assert File.exists?(artifact)
    assert {:ok, written} = LLMDB.Snapshot.read(artifact)
    {expected, _report} = Refresh.build(base(), release, ["openai"])
    assert written["snapshot_id"] == expected["snapshot_id"]
    assert :ok = LLMDB.Snapshot.verify(written)

    # no leftover temp file, and the artifact is what actually loads
    assert File.ls!(dir) |> Enum.sort() == ["base.json", "catalog.json"]

    models = loaded_models(load!(artifact))
    assert models[:openai]["gpt-5"].limits[:context] == 400_000
    assert models[:anthropic]["claude-x"].limits[:context] == 200_000
  end

  test "run/1 is a no-op when the artifact already carries this cut", %{
    dir: dir,
    artifact: artifact
  } do
    base_path = write!(dir, "base.json", base())
    release = doc(@release_cut, %{"openai" => provider("openai", %{"gpt-4o" => 1})})

    opts = [artifact: artifact, base: base_path, providers: ["openai"], fetch: fetch(release)]
    assert {:ok, :updated} = Refresh.run(opts)
    mtime = File.stat!(artifact, time: :posix).mtime

    # the same release again, forced past the freshness check: nothing to
    # write, nothing to notify. This is the ordinary daily case — the release
    # host publishes on a weekly cadence, so most ticks find the cut we already
    # have, and re-writing it would churn every subscriber's window for nothing.
    assert {:ok, :unchanged} = Refresh.run([force: true] ++ opts)
    assert File.stat!(artifact, time: :posix).mtime == mtime

    # a NEWER cut, once the freshness gate opens, does get written
    newer = doc("2026-10-17T00:00:00Z", %{"openai" => provider("openai", %{"gpt-4o" => 2})})

    assert {:ok, :updated} = Refresh.run([force: true, fetch: fetch(newer)] ++ opts)
    assert {:ok, %{"generated_at" => "2026-10-17T00:00:00Z"}} = LLMDB.Snapshot.read(artifact)

    # and the timer's own path — not forced — finds it written and skips
    assert {:ok, :skipped} = Refresh.run([fetch: fetch(newer)] ++ opts)
  end

  test "run/1 skips when the artifact is fresh, unless :force is set",
       %{dir: dir, artifact: artifact} do
    base_path = write!(dir, "base.json", base())
    release = doc(@release_cut, %{"openai" => provider("openai", %{"gpt-4o" => 1})})

    opts = [artifact: artifact, base: base_path, providers: ["openai"], fetch: fetch(release)]

    # no artifact at all: due, so it refreshes
    assert {:ok, :updated} = Refresh.run(opts)

    # still fresh: the daily check skips without fetching (the fetcher raises,
    # so a fetch here would be visible as a crash, not a silent skip)
    exploding = fn -> flunk("a fresh artifact must not be fetched for") end
    assert {:ok, :skipped} = Refresh.run([fetch: exploding] ++ opts)

    # the verb forces
    assert {:ok, :unchanged} = Refresh.run([force: true, fetch: fetch(release)] ++ opts)
  end

  test "run/1 reports a fetch failure without touching the artifact", %{
    dir: dir,
    artifact: artifact
  } do
    base_path = write!(dir, "base.json", base())

    assert {:error, {:http_status, 503, "maintenance"}} =
             Refresh.run(
               artifact: artifact,
               base: base_path,
               providers: ["openai"],
               fetch: fn -> {:error, {:http_status, 503, "maintenance"}} end
             )

    refute File.exists?(artifact)
    assert File.ls!(dir) == ["base.json"]
  end

  test "run/1 refuses a body that is not a snapshot document", %{dir: dir, artifact: artifact} do
    base_path = write!(dir, "base.json", base())

    assert {:error, {:unexpected_release_document, ["not", "a", "document"]}} =
             Refresh.run(
               artifact: artifact,
               base: base_path,
               providers: ["openai"],
               fetch: fn -> {:ok, ["not", "a", "document"]} end
             )

    refute File.exists?(artifact)
  end

  test "run/1 survives a crash in the fetcher, with the reason", %{dir: dir, artifact: artifact} do
    base_path = write!(dir, "base.json", base())

    assert {:error, {:crashed, message}} =
             Refresh.run(
               artifact: artifact,
               base: base_path,
               providers: ["openai"],
               fetch: fn -> raise "connection reset" end
             )

    assert message =~ "connection reset"
    refute File.exists?(artifact)
  end

  test "run/1 accepts the document itself as well as the release store's envelope",
       %{dir: dir, artifact: artifact} do
    base_path = write!(dir, "base.json", base())
    release = doc(@release_cut, %{"openai" => provider("openai", %{"gpt-4o" => 1})})

    assert {:ok, :updated} =
             Refresh.run(
               artifact: artifact,
               base: base_path,
               providers: ["openai"],
               fetch: fn -> {:ok, release} end
             )
  end

  test "run/1 with a provider list that names nothing swappable is unchanged", %{
    dir: dir,
    artifact: artifact
  } do
    base_path = write!(dir, "base.json", base())
    release = doc(@release_cut, %{"openai" => provider("openai", %{"gpt-4o" => 1})})

    assert {:ok, :unchanged} =
             Refresh.run(
               artifact: artifact,
               base: base_path,
               providers: [],
               fetch: fetch(release)
             )

    refute File.exists?(artifact)
  end

  test "run/1 without a :fetch uses the configured transport, exactly once",
       %{dir: dir, artifact: artifact} do
    base_path = write!(dir, "base.json", base())
    release = doc(@release_cut, %{"openai" => provider("openai", %{"gpt-4o" => 1})})

    # the app configures the transport (config/test.exs does, for the real
    # run: the release host); a test may too, which is how this exercises the
    # DEFAULT argument without a network. `run/1` must CALL it once — an
    # arity-0 default reached through a lazy getter would be called at the
    # option lookup instead, handing the merge an already-fetched document.
    previous = Application.get_env(:coding_agent, :catalog_refresh)
    Application.put_env(:coding_agent, :catalog_refresh, fetch: fn -> {:ok, release} end)
    on_exit(fn -> Application.put_env(:coding_agent, :catalog_refresh, previous) end)

    assert {:ok, :updated} =
             Refresh.run(artifact: artifact, base: base_path, providers: ["openai"], force: true)

    assert {:ok, %{"generated_at" => @release_cut}} = LLMDB.Snapshot.read(artifact)
  end

  # -- describe/1 and the test-run knob ---------------------------------------

  test "describe/1 names a failure instead of dumping a tuple" do
    assert Refresh.describe(:not_found) =~ "no snapshot"
    assert Refresh.describe({:http_status, 404, "Not Found"}) =~ "HTTP 404"
    assert Refresh.describe({:verify_failed, :enoent}) =~ "would not load"
    assert Refresh.describe({:verify_failed, :enoent}) =~ "enoent"
    assert Refresh.describe({:unexpected_release_document, %{"a" => 1}}) =~ "not a snapshot"
    assert Refresh.describe({:crashed, "boom"}) == "boom"
    assert Refresh.describe(%RuntimeError{message: "boom"}) =~ "boom"
    assert Refresh.describe({:something, :else}) =~ "something"
  end

  # The knob that keeps the suite offline: `Catalog` arms no timer at all under
  # `interval_ms: :never`, and the refresh pipeline only runs when a test calls
  # it. Without this, a full-suite run would download ~11 MB from GitHub.
  test "the test run never arms the refresh timer" do
    assert Refresh.interval_ms() == :never
  end
end
