defmodule CodingAgent.Core.Session.StoreTest do
  use ExUnit.Case, async: false

  # Persistence (4a): round-trip, fail-closed corruption handling, and
  # the resume semantics (running → idle, subscribers dropped).

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.Store
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
  end

  describe "list/0" do
    test "lists sessions newest-first with metadata" do
      a = build_state("list-a-#{System.unique_integer()}")
      :ok = Store.save(a)
      Process.sleep(1100)
      b = build_state("list-b-#{System.unique_integer()}")
      :ok = Store.save(b)

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
  end

  describe "live session persistence" do
    test "decide on an interrupted session persists; resume carries the exchange" do
      root = Path.join(System.tmp_dir!(), "store-live-#{System.unique_integer()}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      id = "live-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: root,
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
end
