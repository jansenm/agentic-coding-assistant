defmodule CodingAgent.Core.Session.StoreTest do
  use ExUnit.Case, async: false

  # Persistence (4a): round-trip, fail-closed corruption handling, and
  # the resume semantics (running → idle, subscribers dropped).

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.Store
  alias CodingAgent.Core.Session.State
  alias ReqLLM.Context

  @test_dir System.tmp_dir!() |> Path.join("agent-store-test-#{System.unique_integer()}")

  # the dir active at test-compile time: the global test_helper sets an
  # isolated dir; restore it on exit instead of nil (nil would expose
  # the user's real storage to later tests)
  @prev_store_dir Application.compile_env(:coding_agent, :store_dir)

  setup do
    # isolate: tests run against their own dir, never the user's real
    # session storage (an earlier version wiped real sessions once)
    Application.put_env(:coding_agent, :store_dir, @test_dir)
    File.rm_rf!(@test_dir)

    on_exit(fn ->
      Application.put_env(:coding_agent, :store_dir, @prev_store_dir)
      File.rm_rf!(@test_dir)
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

  describe "fail-closed loading" do
    test "missing file errors" do
      assert {:error, :enoent} = Store.load("never-existed-#{System.unique_integer()}")
    end

    test "corrupt bytes error instead of crashing" do
      id = "corrupt-#{System.unique_integer()}"
      File.mkdir_p!(@test_dir)
      File.write!(Store.path(id), <<1, 2, 3, "garbage">>)
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
      older =
        state
        |> Map.drop([:base_policy, :base_prompt, :agent])

      payload = :erlang.term_to_binary({1, older})
      File.mkdir_p!(@test_dir)
      File.write!(Store.path(id), payload)

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

      payload = :erlang.term_to_binary({1, older})
      File.mkdir_p!(@test_dir)
      File.write!(Store.path(id), payload)

      assert {:ok, loaded} = Store.load(id)
      assert %Permissions{} = loaded.policy
      assert loaded.policy.disabled == []
      # the healed policy is usable: apply_agent does not raise
      assert %Permissions{} = Permissions.apply_agent(loaded.policy, %{tools: ["read_file"]})
    end

    test "wrong version errors" do
      id = "wrongver-#{System.unique_integer()}"
      state = build_state(id)
      payload = :erlang.term_to_binary({99, state})
      File.mkdir_p!(@test_dir)
      File.write!(Store.path(id), payload)
      assert {:error, {:not_a_session_file, 99}} = Store.load(id)
    end

    test "foreign payload (not a state tuple) errors" do
      id = "foreign-#{System.unique_integer()}"
      payload = :erlang.term_to_binary({1, :hello})
      File.mkdir_p!(@test_dir)
      File.write!(Store.path(id), payload)
      assert {:error, _} = Store.load(id)
    end

    test "a NEWER snapshot with unknown struct keys fails closed, not KeyError" do
      id = "newer-#{System.unique_integer()}"
      state = build_state(id)

      # simulate a snapshot written by a later app version: extra keys
      # in the struct map (same format_version 1) — struct!/1 rejects
      # unknown keys, so the old binary must drop them, not crash
      newer =
        state
        |> Map.put(:a_field_from_the_future, 42)
        |> Map.put(:another_future_key, "x")

      payload = :erlang.term_to_binary({1, newer})
      File.mkdir_p!(@test_dir)
      File.write!(Store.path(id), payload)

      # must not raise; unknown keys dropped, known state restored
      assert {:ok, loaded} = Store.load(id)
      assert loaded.id == id
      assert loaded.model == "ollama:test-model"
    end
  end

  describe "list/0" do
    test "lists sessions newest-first with metadata" do
      a = build_state("list-a-#{System.unique_integer()}")
      :ok = Store.save(a)
      b = build_state("list-b-#{System.unique_integer()}")
      :ok = Store.save(b)

      # order by mtime: set them explicitly instead of sleeping a second
      # for the filesystem clock to separate the two saves
      now = System.os_time(:second)
      File.touch!(Store.path(a.id), now - 60)
      File.touch!(Store.path(b.id), now)

      sessions = Store.list()
      ids = Enum.map(sessions, & &1.id)
      assert b.id in ids and a.id in ids
      assert Enum.find_index(ids, &(&1 == b.id)) < Enum.find_index(ids, &(&1 == a.id))

      newest = Enum.find(sessions, &(&1.id == b.id))
      assert newest.model == "ollama:test-model"
      assert newest.status == :idle
      assert %DateTime{} = newest.saved_at
    end

    test "empty dir yields empty list" do
      assert Store.list() == []
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
      # same shape as list/0 (no scope_root leaks into the summary)
      assert %{id: _, saved_at: %DateTime{}, model: "m-a", status: :idle} = hd(in_a)
      refute Map.has_key?(hd(in_a), :scope_root)

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

    assert loaded.usage == %{input_tokens: 0, output_tokens: 0, cost: nil}
    assert loaded.status == :idle
    Store.delete(old_shaped.id)
  end

  # the store_dir override is compile-env-sealed in some paths; these
  # rename tests follow the same isolate pattern as above
  test "rename/2 re-ids the file; live sessions are told so saves follow" do
    ctx = Context.new([Context.user("hi")])

    st =
      State.new(
        id: "ren-a",
        context: ctx,
        model: "m",
        status: :idle,
        scope_root: @test_dir
      )

    Store.save(st)

    # no live process: pure file dance
    assert {:ok, "ren-b"} = Store.rename("ren-a", "ren-b")
    refute File.exists?(Store.path("ren-a"))
    assert File.exists?(Store.path("ren-b"))
    assert {:ok, %{id: "ren-b"}} = Store.load("ren-b")
  end

  test "rename/2 errors: invalid name and collision" do
    ctx = Context.new([Context.user("hi")])

    for id <- ["ren-c", "ren-d"] do
      State.new(id: id, context: ctx, model: "m", status: :idle, scope_root: @test_dir)
      |> Store.save()
    end

    assert {:error, :exists} = Store.rename("ren-c", "ren-d")
    assert {:error, :invalid_name} = Store.rename("ren-c", "")
    assert {:error, :invalid_name} = Store.rename("ren-c", "  ")
    assert {:error, :invalid_name} = Store.rename("ren-c", "ren-c")
  end

  test "rename/2 refuses path-injecting ids" do
    ctx = Context.new([Context.user("hi")])

    State.new(id: "ren-inj", context: ctx, model: "m", status: :idle, scope_root: @test_dir)
    |> Store.save()

    # every one of these would escape or collide with the sessions dir;
    # none may rename, and the original must stay intact
    for bad <- ["../evil", "../../x", "a/b", "a\\b", ".hidden", ".tmp-1", "-lead", "/abs"] do
      assert {:error, :invalid_name} = Store.rename("ren-inj", bad),
             "expected #{inspect(bad)} to be refused"
    end

    assert File.exists?(Store.path("ren-inj"))
    assert {:ok, %{id: "ren-inj"}} = Store.load("ren-inj")

    # a valid dotted/dashed name still works (the guard is not too tight)
    assert {:ok, "ren.v2-ok"} = Store.rename("ren-inj", "ren.v2-ok")
    assert File.exists?(Store.path("ren.v2-ok"))
  end

  test "rename/2 notifies a live session: its next save lands on the new id" do
    ctx = Context.new([Context.user("hi")])

    st =
      State.new(
        id: "ren-live",
        context: ctx,
        model: "m",
        status: :idle,
        scope_root: @test_dir
      )

    Store.save(st)

    # note: store_dir is overridden for this test, so the registry-keyed
    # live session started by the supervisor persists into @test_dir too
    {:ok, pid} =
      Session.Supervisor.start_session(id: "ren-live", scope_root: @test_dir)

    assert {:ok, "ren-live2"} = Store.rename("ren-live", "ren-live2")
    assert Process.alive?(pid)

    # the live process re-saves on turn boundaries; force one via a
    # state fetch + save (persist uses the in-memory id — the notify
    # must have landed before rename returned)
    live = Registry.lookup(CodingAgent.Registry, {:session, "ren-live"}) |> hd() |> elem(0)
    s = :sys.get_state(live)
    assert s.id == "ren-live2"
    assert :ok = Store.save(s)

    # no stale resurrection: old file gone, new file present
    refute File.exists?(Store.path("ren-live"))
    assert File.exists?(Store.path("ren-live2"))
  end
end
