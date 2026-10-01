defmodule CodingAgent.Core.Providers.CatalogTest do
  @moduledoc """
  Unit tests for the catalog boundary (ADR 039): the non-blocking window
  lookup and the subscribe/notify contract. These run against the real
  (bundled) llm_db snapshot; the app's warm makes it ready within a few
  seconds, which `wait_ready/0` covers.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Providers.Catalog

  # The catalog warms in a `handle_continue` after app start, so it may
  # still be loading when the first test runs. Poll briefly for readiness
  # rather than assume a fixed delay.
  defp wait_ready(deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    cond do
      Catalog.ready?() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("catalog never became ready")
      true -> Process.sleep(20) && wait_ready(deadline)
    end
  end

  test "a cataloged model resolves its window" do
    wait_ready()
    assert {:ok, 128_000} = Catalog.context_window("openai:gpt-4o")
  end

  test "an unknown model is :unknown (not an error)" do
    wait_ready()
    assert :unknown = Catalog.context_window("ollama_cloud:not-a-real-model")
  end

  test "a nil model is :unknown" do
    assert :unknown = Catalog.context_window(nil)
  end

  test "subscribe delivers {:catalog, :updated} when already loaded" do
    wait_ready()
    assert :ok = Catalog.subscribe()
    assert_receive {:catalog, :updated}, 1000
  end

  # The `:loading` branch: while llm_db has no snapshot, the lookup must
  # answer `:loading` (never block) so `Config.context_window/2` can fall
  # back. This test owns the global persistent_term store for its duration
  # (sync tests run after the async ones), and reloads before it exits so
  # later sync tests still see a catalog.
  test "while loading, the window is :loading and Config falls back" do
    LLMDB.Catalog.clear!()
    on_exit(fn -> LLMDB.load() end)

    refute Catalog.ready?()
    assert :loading = Catalog.context_window("openai:gpt-4o")

    snapshot = %CodingAgent.Core.Config{config: %{}}
    assert CodingAgent.Core.Config.context_window(snapshot, "openai:gpt-4o") == 500_000
  end

  # The startup-hang fix end to end: a session that mounts while the
  # catalog is still loading takes the fallback window, then re-resolves
  # to the real one when the catalog signals readiness (ADR 039). This is
  # the race the background warm is designed around.
  test "a session mounted while loading re-resolves once the catalog is ready" do
    alias CodingAgent.Core.Session

    LLMDB.Catalog.clear!()
    on_exit(fn -> LLMDB.load() end)

    id = "catalog-resolve-#{System.unique_integer([:positive])}"
    {:ok, pid} = CodingAgent.Core.Session.Supervisor.start_session(id: id, model: "openai:gpt-4o")
    :ok = Session.subscribe(id)

    # mounted while loading: the fallback window
    assert {:ok, %{context_window: 500_000}} = Session.state(id)

    # the catalog finishes: the session re-resolves and broadcasts
    LLMDB.load()
    send(pid, {:catalog, :updated})

    assert_receive {:agent, ^id, {:context_window, window, soft, hard}}, 2000
    assert window == 128_000
    # hard = max(window - reserve(64k), 0.75*window) = 96_000 (N1 floor);
    # soft = round(window * 0.5) = 64_000
    assert {soft, hard} == {64_000, 96_000}
    assert {:ok, %{context_window: 128_000}} = Session.state(id)

    :ok = Session.stop(id)
  end

  test "an uncataloged model surfaces the assumed window once (review: visible fallback)" do
    alias CodingAgent.Core.Session
    import ExUnit.CaptureLog

    wait_ready()

    id = "window-fallback-#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        {:ok, _pid} =
          CodingAgent.Core.Session.Supervisor.start_session(id: id, model: "ollama_cloud:nope")

        # the window is the default (a guess), and the source says so
        assert {:ok, %{context_window: 500_000, context_window_source: :fallback}} =
                 Session.state(id)

        # a re-resolve (idle model switch, no provider call) warns once ...
        :ok = Session.set_model(id, "ollama_cloud:still-nope")
        # ... and a second uncataloged switch stays quiet
        :ok = Session.set_model(id, "ollama_cloud:also-nope")
        :ok = Session.stop(id)
      end)

    assert log =~ "unknown to the model catalog"
    assert log =~ "context_window"
    # exactly one warning (the second uncataloged switch is silent)
    assert length(String.split(log, "unknown to the model catalog")) == 2
  end

  test "a model switch re-resolves the window (ADR 037 OQ1, review N9)" do
    alias CodingAgent.Core.Session

    wait_ready()

    id = "model-switch-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      CodingAgent.Core.Session.Supervisor.start_session(id: id, model: "openai:gpt-4o")

    # 128k for gpt-4o
    assert {:ok, %{context_window: 128_000}} = Session.state(id)

    # switch to a model with a much smaller window: the budget must follow,
    # else the provider rejects a context the budget thought fit.
    :ok = Session.set_model(id, "openai:gpt-3.5-turbo")
    assert {:ok, %{model: "openai:gpt-3.5-turbo", context_window: 16_385}} = Session.state(id)

    :ok = Session.stop(id)
  end

  test "an idle agent switch to a model-pinned agent re-resolves the window (N26)" do
    alias CodingAgent.Core.Session

    wait_ready()

    root = Path.join(System.tmp_dir!(), "agent-window-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".coding-agent/agents"))
    on_exit(fn -> File.rm_rf!(root) end)

    # a primary agent whose definition pins a much smaller model (ADR 017)
    File.write!(
      Path.join(root, ".coding-agent/agents/pinned.md"),
      "---\nname: pinned\ndescription: small model\nmode: primary\nmodel: openai:gpt-3.5-turbo\n---\nbody\n"
    )

    id = "agent-window-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: id,
        model: "openai:gpt-4o",
        scope_root: root,
        agent: "build"
      )

    # starts on build (no pinned model) -> inherits gpt-4o's 128k
    assert {:ok, %{context_window: 128_000}} = Session.state(id)

    # switch to the pinned agent: the effective model shrinks to 16k and
    # the window must follow
    assert {:ok, _} = Session.set_agent(id, "pinned")
    assert {:ok, %{context_window: 16_385}} = Session.state(id)

    # and back to build: the window widens again
    assert {:ok, _} = Session.set_agent(id, "build")
    assert {:ok, %{context_window: 128_000}} = Session.state(id)

    :ok = Session.stop(id)
  end
end
