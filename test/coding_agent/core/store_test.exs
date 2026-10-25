defmodule CodingAgent.Core.Session.StoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Persistence (4a): round-trip, fail-closed corruption handling, and
  # the resume semantics (running → idle, subscribers dropped).

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.Store
  alias CodingAgent.Core.Session.State
  alias ReqLLM.Context

  # @store_path is the DB FILE (the store is one SQLite db); @scope_dir is
  # a real directory used where a test needs a scope root.
  @tmp_root System.tmp_dir!() |> Path.join("agent-store-test-#{System.unique_integer()}")
  @store_path Path.join(@tmp_root, "store.db")
  @scope_dir Path.join(@tmp_root, "scope")

  # the store active at test-compile time: the global test_helper sets an
  # isolated path; restore it on exit instead of nil (nil would expose
  # the user's real storage to later tests)
  @prev_store_dir Application.compile_env(:coding_agent, :store_path)

  setup do
    # isolate: tests run against their own store, never the user's real
    # session storage (an earlier version wiped real sessions once)
    Application.put_env(:coding_agent, :store_path, @store_path)
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@scope_dir)
    CodingAgent.TestScope.declare_window!(@scope_dir)

    on_exit(fn ->
      Application.put_env(:coding_agent, :store_path, @prev_store_dir)
      File.rm_rf!(@tmp_root)
    end)

    :ok
  end

  describe "save/load round-trip" do
    test "a fresh state survives with its context intact" do
      id = "store-#{System.unique_integer()}"

      context =
        Context.new()
        |> Context.append(ReqLLM.Context.system("sys"))
        |> Context.append(ReqLLM.Context.user("hello"))

      state =
        CodingAgent.Core.Session.State.new(
          id: id,
          context: context,
          model: "ollama:test-model",
          status: :idle,
          scope_root: "/tmp",
          policy: Permissions.load(nil, nil)
        )

      assert :ok = Store.save(state)

      assert {:ok, loaded} = Store.load(id)
      assert loaded.id == id
      assert loaded.model == "ollama:test-model"
      assert loaded.scope_root == "/tmp"
      assert length(ReqLLM.Context.to_list(loaded.context)) == 2
      # runtime-only field reset
      assert loaded.subscribers == []
      # policy survives as a struct
      assert loaded.policy != nil
    end

    test "a conversation with tool exchanges round-trips" do
      id = "store-tool-#{System.unique_integer()}"

      # build a context the way the real loop does: system + user + a
      # tool result message
      context =
        Context.new()
        |> Context.append(ReqLLM.Context.system("sys"))
        |> Context.append(ReqLLM.Context.user("run the test"))
        |> Context.append(ReqLLM.Context.tool_result_message("shell", "call-1", "exit 0"))

      state =
        CodingAgent.Core.Session.State.new(
          id: id,
          context: context,
          model: "ollama:test-model",
          status: :idle
        )

      :ok = Store.save(state)
      {:ok, loaded} = Store.load(id)

      [first, second, third] = ReqLLM.Context.to_list(loaded.context)
      assert first.role == :system
      assert second.role == :user
      assert third.role == :tool
      assert third.tool_call_id == "call-1"
    end

    test "interrupted sessions resume interrupted; running/error resume idle" do
      base = fn status ->
        CodingAgent.Core.Session.State.new(
          id: "s-#{System.unique_integer()}",
          context: Context.new(),
          model: "m",
          status: status
        )
      end

      interrupted = base.(:interrupted)
      :ok = Store.save(interrupted)
      assert {:ok, loaded} = Store.load(interrupted.id)
      assert loaded.status == :interrupted

      running = base.(:running)
      :ok = Store.save(running)
      assert {:ok, loaded} = Store.load(running.id)
      assert loaded.status == :idle
    end
  end

  # Review N124: the state dir is created OUTSIDE `run_fun/2`, so a failing
  # `mkdir_p` used to raise out of `handle_call/3` — four crashes in five
  # seconds exhausted the root supervisor's restart budget and took the
  # whole application tree (registry, catalog, sessions) with it.
  defp break_store_dir! do
    # a FILE where the parent of the db would have to be a directory
    blocker = Path.join(@tmp_root, "not-a-dir")
    File.write!(blocker, "x")
    Application.put_env(:coding_agent, :store_path, Path.join([blocker, "sub", "store.db"]))
    :ok
  end

  describe "an unopenable store is an error, not a crash (N124)" do
    test "the open error is returned and the store process survives" do
      store = Process.whereis(Store)
      :ok = break_store_dir!()

      for _ <- 1..4 do
        assert {:error, {:store_open_failed, :enotdir}} = Store.ids()
      end

      assert Process.whereis(Store) == store
    end

    test "the checkpoint keep-set is an error, never a smaller set" do
      :ok = break_store_dir!()

      # Returning `[]`/a partial list here would make every persisted ref
      # look like an orphan — the sweep would delete checkpoints of
      # sessions it simply could not read.
      assert {:error, {:store_open_failed, :enotdir}} = Session.checkpoint_keep_set("n124")
    end
  end

  describe "fail-closed loading" do
    test "missing file errors" do
      assert {:error, :enoent} = Store.load("never-existed-#{System.unique_integer()}")
    end

    test "corrupt bytes error instead of crashing" do
      id = "corrupt-#{System.unique_integer()}"
      :ok = Store.debug_put(id, <<1, 2, 3, "garbage">>, encode: false)
      assert {:error, _} = Store.load(id)
    end

    test "an OLDER snapshot missing new struct fields loads with defaults" do
      # regression: `struct!/1` (map form) stopped applying struct
      # defaults in Elixir 1.20, so a snapshot written before a field
      # existed raised "key :base_policy not found" on load. Loading
      # must fill missing fields with their defaults.
      id = "older-#{System.unique_integer()}"
      state = build_state(id)

      # simulate a snapshot from before base_policy/base_prompt/agent:
      # drop those keys entirely
      older = Map.drop(state, [:base_policy, :base_prompt, :agent])

      :ok = Store.debug_put(id, {2, older})

      assert {:ok, loaded} = Store.load(id)
      assert loaded.base_policy == nil
      assert loaded.base_prompt == nil
      assert loaded.agent == nil
      # and every other field is present (struct, not a bare map)
      assert %CodingAgent.Core.Session.State{} = loaded
      assert Map.keys(loaded) |> Enum.sort() == Map.keys(state) |> Enum.sort()
    end

    test "an OLDER nested policy missing :disabled is healed (Tab crash)" do
      # regression: the same Elixir 1.20 trap one level down. An old
      # snapshot carries a %Permissions{} from before `:disabled`
      # existed; apply_agent/2 (Tab) reads policy.disabled and crashed
      # with "key :disabled not found". Loading must heal nested
      # structs too.
      id = "nested-#{System.unique_integer()}"
      state = build_state(id)

      old_policy = %{enabled: [], entries: %{}} |> Map.put(:__struct__, Permissions)
      older = %{state | policy: old_policy}

      :ok = Store.debug_put(id, {2, older})

      assert {:ok, loaded} = Store.load(id)
      assert %Permissions{} = loaded.policy
      assert loaded.policy.disabled == []
      # the healed policy is usable: apply_agent does not raise
      assert %Permissions{} = Permissions.apply_agent(loaded.policy, %{tools: ["read_file"]})
    end

    test "wrong version errors" do
      id = "wrongver-#{System.unique_integer()}"
      :ok = Store.debug_put(id, {99, build_state(id)})
      assert {:error, {:not_a_session_file, 99}} = Store.load(id)
    end

    test "foreign payload (not a state tuple) errors" do
      id = "foreign-#{System.unique_integer()}"
      :ok = Store.debug_put(id, {2, :hello})
      assert {:error, _} = Store.load(id)
    end

    test "a NEWER snapshot with unknown struct keys fails closed, not KeyError" do
      id = "newer-#{System.unique_integer()}"
      state = build_state(id)

      # simulate a snapshot written by a later app version: extra keys
      # in the struct map (same format_version 1) — struct!/1 rejects
      # unknown keys, so the old binary must drop them, not crash
      newer = state |> Map.put(:a_field_from_the_future, 42) |> Map.put(:another_future_key, "x")

      :ok = Store.debug_put(id, {2, newer})

      # must not raise; unknown keys dropped, known state restored
      assert {:ok, loaded} = Store.load(id)
      assert loaded.id == id
      assert loaded.model == "ollama:test-model"
    end
  end

  describe "save failure is contained" do
    test "a failed save returns an error and leaves no open transaction" do
      # regression: exec/3 asserted `:done = step(...)`, so a constraint
      # violation RAISED a MatchError instead of returning {:error, _}.
      # save/1's `with` never caught it, and the abandoned write
      # transaction held a lock — every later save then failed after
      # busy_timeout. Found by forcing a NOT NULL violation.
      good =
        CodingAgent.Core.Session.State.new(
          id: "savefail-#{System.unique_integer([:positive])}",
          context: Context.new([Context.user("hi")]),
          model: "m",
          status: :idle
        )

      # a nil session id violates the messages NOT NULL constraint; the
      # warning is expected, so capture it to keep the output clean
      log = capture_log(fn -> assert {:error, _} = Store.save(%{good | id: nil}) end)
      assert log =~ "session store save failed"

      # the store is not wedged: a valid save still works
      assert :ok = Store.save(good)
      assert {:ok, loaded} = Store.load(good.id)
      assert length(Context.to_list(loaded.context)) == 1
    end

    test "many concurrent writers all succeed, with no write-lock starvation" do
      # Regression for the store flake. The store used to open a NEW SQLite
      # connection per call (a leftover from the FILE-store shape — one
      # action was one File.read/write). The suite's many processes then
      # raced one DB file, and SQLite's unfair busy handler starved waiters:
      # `{:store_open_failed, "database is locked"}` and silent empty
      # listings. The store now OWNS one connection (a GenServer), so this
      # VM never presents a second one. Measured before: 29/32 writers
      # failed; the burst below is well past that point.
      parent = self()

      ids =
        for i <- 1..60 do
          id = "concurrent-#{System.unique_integer([:positive])}-#{i}"

          spawn(fn ->
            state =
              State.new(
                id: id,
                context: Context.new([Context.user("hi #{i}")]),
                model: "m",
                status: :idle
              )

            send(parent, {id, Store.save(state)})
          end)

          id
        end

      results =
        for _ <- 1..60,
            do:
              (receive do
                 r -> r
               after
                 15_000 -> {:timeout, {:error, :timeout}}
               end)

      bad = Enum.reject(results, fn {_id, r} -> r == :ok end)
      assert bad == [], "writers failed: #{inspect(Enum.take(bad, 5))}"

      # and every one is really listed (a silent empty listing was the
      # other symptom)
      listed = Store.list() |> Enum.map(& &1.id) |> MapSet.new()
      for id <- ids, do: assert(MapSet.member?(listed, id))
    end
  end

  describe "list/0" do
    test "lists sessions newest-first with metadata" do
      a = build_state("list-a-#{System.unique_integer()}")
      :ok = Store.save(a)
      b = build_state("list-b-#{System.unique_integer()}")
      :ok = Store.save(b)

      # order by saved_at: set them explicitly instead of sleeping for
      # the clock to separate the two saves
      now = DateTime.to_unix(DateTime.utc_now(), :millisecond)
      :ok = Store.debug_set_saved_at(a.id, now - 60_000)
      :ok = Store.debug_set_saved_at(b.id, now)

      sessions = Store.list()
      ids = Enum.map(sessions, & &1.id)
      assert b.id in ids and a.id in ids
      assert Enum.find_index(ids, &(&1 == b.id)) < Enum.find_index(ids, &(&1 == a.id))

      newest = Enum.find(sessions, &(&1.id == b.id))
      assert newest.model == "ollama:test-model"
      assert newest.status == :idle
      assert %DateTime{} = newest.saved_at
      # storage footprint (ADR 020 R13): a real byte count per session
      assert is_integer(newest.size) and newest.size > 0
    end

    test "empty store yields an empty list" do
      assert Store.list() == []
    end

    test "listing reads columns, never decodes a state (R9)" do
      # A row whose state BLOB is garbage still lists: the summary comes
      # from columns, so listing cost no longer scales with total bytes
      # and a single corrupt session cannot break the picker.
      id = "list-corrupt-#{System.unique_integer()}"

      :ok =
        Store.debug_put(id, <<1, 2, 3, "garbage">>,
          encode: false,
          model: "m-x",
          scope_root: @scope_dir
        )

      summaries = Store.list()
      entry = Enum.find(summaries, &(&1.id == id))
      assert entry.model == "m-x"
      assert Path.expand(entry.scope_root) == Path.expand(@scope_dir)
      # and only the explicitly requested metadata fields are present
      assert Map.keys(entry) |> Enum.sort() ==
               [:id, :model, :saved_at, :scope_root, :size, :status]
    end

    test "list_in/1 filters by scope_root with the same summary fields" do
      root_a = Path.join(System.tmp_dir!(), "store-in-a-#{System.unique_integer()}")
      root_b = Path.join(System.tmp_dir!(), "store-in-b-#{System.unique_integer()}")
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)

      a =
        State.new(
          id: "in-a-#{System.unique_integer()}",
          context: Context.new(),
          model: "m-a",
          status: :idle,
          scope_root: root_a
        )

      b =
        State.new(
          id: "in-b-#{System.unique_integer()}",
          context: Context.new(),
          model: "m-b",
          status: :idle,
          scope_root: root_b
        )

      :ok = Store.save(a)
      :ok = Store.save(b)

      in_a = Store.list_in(root_a)
      assert Enum.map(in_a, & &1.id) == [a.id]

      # same shape as list/0: the summary now also carries scope_root
      # (the picker groups/filters by project — ADR 020) and size (R13)
      assert %{id: _, saved_at: %DateTime{}, model: "m-a", status: :idle, size: size} = hd(in_a)
      assert is_integer(size) and size > 0
      assert Path.expand(hd(in_a).scope_root) == Path.expand(root_a)

      assert Enum.map(Store.list_in(root_b), & &1.id) == [b.id]
      assert Store.list_in(Path.join(System.tmp_dir!(), "nope-#{System.unique_integer()}")) == []
    end
  end

  describe "live session persistence" do
    test "decide on an interrupted session persists; resume carries the exchange" do
      root = Path.join(System.tmp_dir!(), "store-live-#{System.unique_integer()}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      id = "live-#{System.unique_integer()}"

      # ask-policy file: the amendment made write_file allow-by-default,
      # and this test is ABOUT the interrupted persistence path
      toml_path = Path.join(root, "permissions.toml")

      File.write!(toml_path, """
      [permissions.write_file]
      "*" = "ask"
      """)

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: root,
          policy: CodingAgent.Core.Permissions.load(nil, toml_path),
          test_mode: true
        )

      :ok =
        Session.debug_gate(id, [
          %{id: "c1", name: "write_file", arguments: %{"path" => "x.txt", "content" => "hello"}}
        ])

      # the interruption snapshot must already be on disk
      assert {:ok, persisted} = Store.load(id)
      assert persisted.status == :interrupted

      {:ok, _} = Session.decide(id, [%{id: "c1", decision: :approve}])
      assert {:ok, after_decision} = Store.load(id)
      assert after_decision.status == :idle

      # the tool result is IN the persisted context: resuming a new
      # process with this state gives the model the full history
      msgs = ReqLLM.Context.to_list(after_decision.context)
      assert Enum.any?(msgs, &(&1.role == :tool))
    end
  end

  defp build_state(id) do
    CodingAgent.Core.Session.State.new(
      id: id,
      context: Context.new(),
      model: "ollama:test-model",
      status: :idle
    )
  end

  defp state_with(id, messages) do
    CodingAgent.Core.Session.State.new(
      id: id,
      context: Context.new(messages),
      model: "ollama:test-model",
      status: :idle
    )
  end

  describe "resolve_id/1 (prefix/suffix matching, unique)" do
    test "exact id resolves" do
      :ok = Store.save(build_state("abc-123"))
      assert {:ok, "abc-123"} = Store.resolve_id("abc-123")
    end

    test "unique suffix resolves (the '1730' -> tui-1730 case)" do
      :ok = Store.save(build_state("tui-1730"))
      assert {:ok, "tui-1730"} = Store.resolve_id("1730")
    end

    test "unique prefix resolves" do
      :ok = Store.save(build_state("tui-42abc"))
      assert {:ok, "tui-42abc"} = Store.resolve_id("tui-42")
    end

    test "ambiguous matches error with candidates" do
      :ok = Store.save(build_state("dup-aa-1"))
      :ok = Store.save(build_state("dup-ab-2"))
      assert {:error, {:ambiguous_id, ids}} = Store.resolve_id("dup")
      assert length(ids) == 2
    end

    test "missing id errors" do
      assert {:error, :enoent} = Store.resolve_id("never-999")
    end
  end

  test "snapshots saved before a struct field existed still load (no KeyError)" do
    # simulate an old snapshot: a State-shaped struct WITHOUT the
    # :usage key (struct update syntax would raise against it)
    old_shaped =
      [
        :id,
        :context,
        :model,
        :status,
        :last_error,
        :scope_root,
        :policy,
        :pending_tool_calls,
        :subscribers,
        :tool_rounds,
        :test_mode
      ]
      |> Map.new(&{&1, nil})
      |> Map.put(:__struct__, CodingAgent.Core.Session.State)
      |> Map.put(:id, "old-shaped-#{System.unique_integer([:positive])}")
      |> Map.put(:context, ReqLLM.Context.new())
      |> Map.put(:model, "m")
      |> Map.put(:status, :idle)

    Store.save(old_shaped)
    {:ok, loaded} = Store.load(old_shaped.id)

    # usage heals the missing field into the canonical struct
    assert loaded.usage == CodingAgent.Core.Session.Usage.new()
    # the round timing did not exist in that snapshot either (I1)
    assert loaded.timing == CodingAgent.Core.Session.Timing.new()
    assert loaded.status == :idle
    Store.delete(old_shaped.id)
  end

  # the store override is compile-env-sealed in some paths; these
  # rename tests follow the same isolate pattern as above
  test "rename/2 re-ids the row; live sessions are told so saves follow" do
    ctx = Context.new([Context.user("hi")])

    st =
      State.new(
        id: "ren-a",
        context: ctx,
        model: "m",
        status: :idle,
        scope_root: @scope_dir
      )

    Store.save(st)

    # no live process: pure row dance
    assert {:ok, "ren-b"} = Store.rename("ren-a", "ren-b")
    assert {:error, :enoent} = Store.load("ren-a")
    assert {:ok, %{id: "ren-b"}} = Store.load("ren-b")
  end

  test "delete/1 and rename/2 carry the session scratch directory (ADR 022)" do
    ctx = Context.new([Context.user("hi")])
    alias CodingAgent.Core.Session.Scratch

    id = "scratch-life-#{System.unique_integer([:positive])}"
    new_id = id <> "-ren"

    on_exit(fn ->
      Scratch.remove(Scratch.path(id))
      Scratch.remove(Scratch.path(new_id))
    end)

    State.new(id: id, context: ctx, model: "m", status: :idle, scope_root: @scope_dir)
    |> Store.save()

    # a session that actually used /tmp has a scratch dir
    Scratch.ensure(Scratch.path(id))
    assert File.dir?(Scratch.path(id))

    assert {:ok, ^new_id} = Store.rename(id, new_id)
    refute File.dir?(Scratch.path(id))
    assert File.dir?(Scratch.path(new_id))

    Store.delete(new_id)
    refute File.dir?(Scratch.path(new_id))
  end

  test "rename/2 errors: invalid name and collision" do
    ctx = Context.new([Context.user("hi")])

    for id <- ["ren-c", "ren-d"] do
      State.new(id: id, context: ctx, model: "m", status: :idle, scope_root: @scope_dir)
      |> Store.save()
    end

    assert {:error, :exists} = Store.rename("ren-c", "ren-d")
    assert {:error, :invalid_name} = Store.rename("ren-c", "")
    assert {:error, :invalid_name} = Store.rename("ren-c", "  ")
    assert {:error, :invalid_name} = Store.rename("ren-c", "ren-c")
  end

  test "rename/2 refuses path-injecting ids" do
    ctx = Context.new([Context.user("hi")])

    State.new(id: "ren-inj", context: ctx, model: "m", status: :idle, scope_root: @scope_dir)
    |> Store.save()

    # every one of these would escape the derived scratch path or collide
    # with a hidden name; none may rename, and the original stays intact
    for bad <- ["../evil", "../../x", "a/b", "a\\b", ".hidden", ".tmp-1", "-lead", "/abs"] do
      assert {:error, :invalid_name} = Store.rename("ren-inj", bad),
             "expected #{inspect(bad)} to be refused"
    end

    assert {:ok, %{id: "ren-inj"}} = Store.load("ren-inj")

    # a valid dotted/dashed name still works (the guard is not too tight)
    assert {:ok, "ren.v2-ok"} = Store.rename("ren-inj", "ren.v2-ok")
    assert {:ok, %{id: "ren.v2-ok"}} = Store.load("ren.v2-ok")
  end

  test "rename/2 notifies a live session: its next save lands on the new id" do
    ctx = Context.new([Context.user("hi")])

    st =
      State.new(
        id: "ren-live",
        context: ctx,
        model: "m",
        status: :idle,
        scope_root: @scope_dir
      )

    Store.save(st)

    # note: the store path is overridden for this test, so the registry-keyed
    # live session started by the supervisor persists into @scope_dir too
    {:ok, pid} =
      Session.Supervisor.start_session(id: "ren-live", scope_root: @scope_dir)

    assert {:ok, "ren-live2"} = Store.rename("ren-live", "ren-live2")
    assert Process.alive?(pid)

    # the live process re-saves on turn boundaries; force one via a
    # state fetch + save (persist uses the in-memory id — the notify
    # must have landed before rename returned)
    live = Registry.lookup(CodingAgent.Registry, {:session, "ren-live"}) |> hd() |> elem(0)
    s = :sys.get_state(live)
    assert s.id == "ren-live2"
    assert :ok = Store.save(s)

    # no stale resurrection: old row gone, new row present
    assert {:error, :enoent} = Store.load("ren-live")
    assert {:ok, %{id: "ren-live2"}} = Store.load("ren-live2")
  end

  describe "display view (ADR 020)" do
    test "appends in order with dense seq, and reads back oldest-first" do
      id = "disp-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id))

      :ok = Store.append_display(id, :user, "hello")
      :ok = Store.append_display(id, :reasoning, "hmm")
      :ok = Store.append_display(id, :assistant, "hi back")

      assert [
               %{seq: 0, kind: :user, text: "hello"},
               %{seq: 1, kind: :reasoning, text: "hmm"},
               %{seq: 2, kind: :assistant, text: "hi back"}
             ] = Store.display(id)
    end

    test "carries agent attribution and kind-specific meta" do
      id = "disp-meta-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id))

      :ok = Store.append_display(id, :assistant, "answer", agent: "plan")
      :ok = Store.append_display(id, :tool, "exit 0", meta: {:tool, "shell"})

      [a, t] = Store.display(id)
      assert a.agent == "plan"
      assert t.agent == nil
      assert t.meta == {:tool, "shell"}
    end

    test "is append-only and independent of the agent view" do
      id = "disp-indep-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id))

      :ok = Store.append_display(id, :user, "first")
      :ok = Store.append_display(id, :reasoning, "thought")

      # a compaction-like rewrite of the agent view must not touch display
      compacted = build_state(id) |> Map.put(:context, ReqLLM.Context.new())
      :ok = Store.save(compacted)

      assert length(Store.display(id)) == 2
    end

    test "delete removes the session's display rows (no orphans)" do
      id = "disp-del-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id))
      :ok = Store.append_display(id, :user, "x")

      Store.delete(id)
      assert Store.display(id) == []
    end

    test "rename re-keys the display rows" do
      id = "disp-ren-#{System.unique_integer([:positive])}"
      new_id = id <> "-b"
      :ok = Store.save(build_state(id))
      :ok = Store.append_display(id, :user, "kept")

      assert {:ok, ^new_id} = Store.rename(id, new_id)
      assert Store.display(id) == []
      assert [%{text: "kept"}] = Store.display(new_id)
    end

    test "an unknown kind degrades to :info (never mints an atom)" do
      id = "disp-kind-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id))
      # write a row with a kind the loader has never seen
      :ok = Store.debug_put_display(id, "from_the_future", "x")

      assert [%{kind: :info}] = Store.display(id)
    end
  end

  # ADR 020 S1: cross-session search within the active store. Searches the
  # display view (the plain-text, immutable record) only — the agent view
  # is not grepped by design.
  describe "search/1 (store-wide, S1)" do
    test "finds matching sessions with their matches, newest first" do
      a = "search-a-#{System.unique_integer([:positive])}"
      b = "search-b-#{System.unique_integer([:positive])}"

      :ok = Store.save(build_state(a))
      :ok = Store.append_display(a, :user, "let us talk about the widget factory")
      :ok = Store.append_display(a, :assistant, "the widget is here")

      :ok = Store.save(build_state(b))
      :ok = Store.append_display(b, :user, "unrelated note")
      :ok = Store.append_display(b, :reasoning, "a widget thought")

      now = DateTime.to_unix(DateTime.utc_now(), :millisecond)
      :ok = Store.debug_set_saved_at(a, now - 60_000)
      :ok = Store.debug_set_saved_at(b, now)

      results = Store.search("widget")
      ids = Enum.map(results, & &1.id)

      # newest first
      assert Enum.find_index(ids, &(&1 == b)) < Enum.find_index(ids, &(&1 == a))

      # each entry carries only its own matches, oldest-first within
      entry_a = Enum.find(results, &(&1.id == a))

      assert Enum.map(entry_a.matches, & &1.text) == [
               "let us talk about the widget factory",
               "the widget is here"
             ]

      entry_b = Enum.find(results, &(&1.id == b))
      assert [%{kind: :reasoning, text: "a widget thought"}] = entry_b.matches
    end

    test "is case-insensitive" do
      id = "search-case-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id))
      :ok = Store.append_display(id, :assistant, "The Widget Factory")

      assert [%{id: ^id}] = Store.search("widget factory")
    end

    test "a blank query returns nothing, not everything" do
      id = "search-blank-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id))
      :ok = Store.append_display(id, :user, "anything")

      assert Store.search("") == []
      assert Store.search("   ") == []
    end

    test "LIKE wildcards in the query are literals, not operators" do
      # a query of "%" must not match every row; it matches only a literal %
      id_pct = "search-pct-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id_pct))
      :ok = Store.append_display(id_pct, :user, "coverage hit 100% today")

      id_plain = "search-plain-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id_plain))
      :ok = Store.append_display(id_plain, :user, "no percent here")

      assert [%{id: ^id_pct}] = Store.search("100%")
      assert Store.search("%") |> Enum.map(& &1.id) == [id_pct]
    end

    test "no matches returns an empty list" do
      id = "search-none-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id))
      :ok = Store.append_display(id, :user, "hello")

      assert Store.search("zzz-not-present") == []
    end
  end

  # ADR 020 slice 3b-ii: the agent view is normalized into per-message
  # rows. The context is no longer inside the state BLOB; it is one
  # `messages` row per message, so append is one INSERT and compaction a
  # seq-range delete (the display view stays the immutable record).
  describe "agent view (per-message rows, ADR 020 3b-ii)" do
    test "stores one row per message and reassembles the context on load" do
      id = "msg-#{System.unique_integer([:positive])}"

      messages = [
        ReqLLM.Context.system("sys"),
        ReqLLM.Context.user("hello"),
        ReqLLM.Context.assistant("hi")
      ]

      :ok = Store.save(state_with(id, messages))
      assert Store.debug_message_count(id) == 3

      assert {:ok, loaded} = Store.load(id)
      assert Context.to_list(loaded.context) == messages
    end

    test "the state BLOB no longer carries the context" do
      # the split itself: the stored state has an empty context; the
      # messages live only in their rows
      id = "msg-split-#{System.unique_integer([:positive])}"

      :ok = Store.save(state_with(id, [ReqLLM.Context.system("sys"), ReqLLM.Context.user("hi")]))

      assert {:ok, raw} = Store.debug_raw_state(id)
      assert Context.to_list(raw.context) == []
      # ...and the full load reattaches it
      assert {:ok, loaded} = Store.load(id)
      assert length(Context.to_list(loaded.context)) == 2
    end

    test "appending grows the rows by exactly the appended messages" do
      id = "msg-append-#{System.unique_integer([:positive])}"
      base = [ReqLLM.Context.system("sys"), ReqLLM.Context.user("one")]

      :ok = Store.save(state_with(id, base))
      assert Store.debug_message_count(id) == 2

      grown = base ++ [ReqLLM.Context.assistant("two"), ReqLLM.Context.user("three")]
      :ok = Store.save(state_with(id, grown))

      assert Store.debug_message_count(id) == 4
      assert {:ok, loaded} = Store.load(id)
      assert Context.to_list(loaded.context) == grown
    end

    test "a compaction-like prefix rewrite replaces, not duplicates, rows" do
      # compaction replaces the old prefix with one summary message while
      # keeping the tail. The diff must delete the old span and insert the
      # summary, leaving no stale rows.
      id = "msg-compact-#{System.unique_integer([:positive])}"

      original =
        [ReqLLM.Context.system("sys")] ++
          for(i <- 1..6, do: ReqLLM.Context.user("m#{i}")) ++ [ReqLLM.Context.user("tail-a")]

      :ok = Store.save(state_with(id, original))
      before = Store.debug_message_count(id)

      summary = ReqLLM.Context.user("[summary of earlier messages]")
      compacted = [ReqLLM.Context.system("sys"), summary, ReqLLM.Context.user("tail-a")]

      :ok = Store.save(state_with(id, compacted))

      assert Store.debug_message_count(id) == 3
      assert before == 8

      assert {:ok, loaded} = Store.load(id)
      assert Context.to_list(loaded.context) == compacted
    end

    test "an append after a compaction keeps a dense, ordered sequence" do
      # regression for the seq-density trap: if compaction leaves the kept
      # tail at its old (higher) seqs, a later append at the old length
      # collides or orders wrong. The stored seqs must stay dense.
      id = "msg-seq-#{System.unique_integer([:positive])}"

      original =
        [ReqLLM.Context.system("sys")] ++
          for(i <- 1..8, do: ReqLLM.Context.user("m#{i}"))

      :ok = Store.save(state_with(id, original))

      compacted = [ReqLLM.Context.system("sys"), ReqLLM.Context.user("[summary]")]
      :ok = Store.save(state_with(id, compacted))
      assert Store.debug_message_count(id) == 2

      # append two more messages after the compaction
      grown = compacted ++ [ReqLLM.Context.assistant("answer"), ReqLLM.Context.user("next")]
      :ok = Store.save(state_with(id, grown))

      assert {:ok, loaded} = Store.load(id)
      assert Context.to_list(loaded.context) == grown
      assert Store.debug_message_count(id) == 4
    end

    test "delete removes the message rows (no orphans)" do
      id = "msg-del-#{System.unique_integer([:positive])}"
      :ok = Store.save(state_with(id, [ReqLLM.Context.user("x")]))
      assert Store.debug_message_count(id) == 1

      Store.delete(id)
      assert Store.debug_message_count(id) == 0
      assert {:error, :enoent} = Store.load(id)
    end

    test "rename re-keys the message rows" do
      id = "msg-ren-#{System.unique_integer([:positive])}"
      new_id = id <> "-b"
      msgs = [ReqLLM.Context.system("sys"), ReqLLM.Context.user("kept")]
      :ok = Store.save(state_with(id, msgs))

      assert {:ok, ^new_id} = Store.rename(id, new_id)
      assert Store.debug_message_count(id) == 0
      assert Store.debug_message_count(new_id) == 2

      assert {:ok, loaded} = Store.load(new_id)
      assert Context.to_list(loaded.context) == msgs
    end

    test "a corrupt message row fails the load closed" do
      id = "msg-corrupt-#{System.unique_integer([:positive])}"
      :ok = Store.save(state_with(id, [ReqLLM.Context.user("ok")]))
      :ok = Store.debug_put_message(id, 0, <<1, 2, 3>>, encode: false)

      assert {:error, {:corrupt_message, _}} = Store.load(id)
    end
  end

  # ADR 020, "Schema versioning": PRAGMA user_version + an ordered,
  # forward-only migration list. The agent-view format_version is a
  # separate axis (covered under the load/corruption tests).
  describe "schema versioning" do
    test "a fresh store is stamped at the current schema version" do
      # touch the store (open runs the migrations)
      assert [] = Store.list()

      assert {:ok, 2} = Store.debug_user_version()
    end

    test "an unversioned store is migrated up and stamped" do
      id = "ver-up-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id))

      # a store written before the version marker: schema present, version 0
      :ok = Store.debug_set_user_version(0)

      # next open sees 0 < target and runs the (idempotent) migrations
      assert [%{id: ^id}] = Store.list()
      assert {:ok, 2} = Store.debug_user_version()
      assert {:ok, _} = Store.load(id)
    end

    test "a store written by a newer build fails closed, not guessed" do
      id = "ver-new-#{System.unique_integer([:positive])}"
      :ok = Store.save(build_state(id))

      :ok = Store.debug_set_user_version(999)

      assert {:error, {:store_open_failed, {:store_schema_too_new, 999, 2}}} =
               Store.load(id)
    end

    test "a too-new store does not crash a listing (degrades to empty)" do
      :ok = Store.save(build_state("ver-list-#{System.unique_integer([:positive])}"))
      :ok = Store.debug_set_user_version(999)

      assert [] = Store.list()
    end
  end

  # -- the persisted-struct evolution rule (see Store's moduledoc) -----------

  describe "persisted struct shapes" do
    test "a field added to %Usage{} is pinned here, and only additive changes are free" do
      expected = [
        :__struct__,
        :balance,
        :cached_tokens,
        :cost,
        :cost_basis,
        :input_tokens,
        :last_input_tokens,
        :marker,
        :output_tokens
      ]

      assert CodingAgent.Core.Session.Usage.new() |> Map.keys() |> Enum.sort() == expected, """
      %Usage{} changed shape.

      Additive (a new field WITH A DEFAULT): add its name above and stop —
      `Usage.from_map/1` heals snapshots written before it, and the format
      version stays.

      Anything else (remove, rename, retype, reinterpret): bump
      `Store.@format_version`. Every older snapshot then fails closed with
      "not a session file", which is the honest outcome — a fresh session,
      not a half-understood one.
      """
    end

    test "a field added to %Timing{} is pinned here, and only additive changes are free" do
      expected = [
        :__struct__,
        :last,
        :llm_ms,
        :rounds,
        :started_at,
        :tool_ms,
        :turn_llm_ms,
        :turn_rounds,
        :turn_tool_ms
      ]

      assert CodingAgent.Core.Session.Timing.new() |> Map.keys() |> Enum.sort() == expected, """
      %Timing{} changed shape.

      Additive (a new field WITH A DEFAULT): add its name above and stop —
      `Timing.restore/1` heals snapshots written before it, and the format
      version stays.

      Anything else (remove, rename, retype, reinterpret): bump
      `Store.@format_version`. Every older snapshot then fails closed with
      "not a session file", which is the honest outcome — a fresh session,
      not a half-understood one.
      """
    end
  end
end
