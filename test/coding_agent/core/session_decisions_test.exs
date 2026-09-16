defmodule CodingAgent.Core.Session.DecisionsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session

  @tmp_root System.tmp_dir!() |> Path.join("agent-decisions-#{System.unique_integer()}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)

    %{
      policy: ask_write_policy(),
      scope: %{root: @tmp_root}
    }
  end

  defp ask_write_policy do
    toml = """
    [permissions.write_file]
    "*" = "ask"
    """

    toml_path = Path.join(@tmp_root, "ask-write.toml")
    File.write!(toml_path, toml)
    Permissions.load(nil, toml_path)
  end

  defp tool_call(id, name, args) do
    %{id: id, name: name, arguments: args}
  end

  # The gate is exercised through the public session process, but with a
  # test-only handle_call bypass? No — instead we test the pure decision
  # machinery: the gate splits calls by policy, and resolve_decisions
  # applies approve/edit/reject on a real session process. We drive the
  # session's gate via its internal API using GenServer.call with an
  # injected :gate message (test-visible), avoiding live LLM calls.
  describe "gate integration (ADR 010, LLM-free)" do
    test "write_file defaults to allow-by-policy (ADR 010 amendment): a contained write runs without a pause" do
      policy = Permissions.load(nil, nil)
      assert Permissions.effective(policy, "write_file", "a.txt", "default") == :allow

      id = "write-gate-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          test_mode: true
        )

      :ok =
        Session.debug_gate(id, [
          tool_call("w1", "write_file", %{"path" => "auto.txt", "content" => "auto"})
        ])

      # the amendment's acceptance: NO interruption — debug_gate leaves
      # the synthetic :running status (no LLM loop in test mode), what
      # matters is there is no parked approval
      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      assert state.pending_tool_calls == []
      assert File.read!(Path.join(@tmp_root, "auto.txt")) == "auto"
    end

    test "a repo-side [permissions.write_file] entry still pauses (policy above the class default)" do
      toml_path = Path.join(@tmp_root, "ask-write.toml")

      File.write!(toml_path, """
      [permissions.write_file]
      "*" = "ask"
      """)

      id = "write-gate-ask-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          policy: Permissions.load(nil, toml_path),
          test_mode: true
        )

      :ok =
        Session.debug_gate(id, [
          tool_call("w1", "write_file", %{"path" => "parked.txt", "content" => "parked"})
        ])

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted
      refute File.exists?(Path.join(@tmp_root, "parked.txt"))

      {:ok, _} = Session.decide(id, [%{id: "w1", decision: :approve}])
      assert File.read!(Path.join(@tmp_root, "parked.txt")) == "parked"
    end

    test "read-only calls are auto-allowed under an ask-write policy", %{policy: policy} do
      assert Permissions.effective(policy, "read_file", "a.txt") == :allow
      assert Permissions.effective(policy, "list_dir", "a") == :allow
    end

    test "write calls ask", %{policy: policy} do
      assert Permissions.effective(policy, "write_file", "a.txt") == :ask
    end

    test "denied patterns are denied", %{policy: _policy} do
      toml = """
      [permissions.write_file]
      "secret/**" = "deny"
      """

      path = Path.join(@tmp_root, "p.toml")
      File.write!(path, toml)
      deny_policy = Permissions.load(nil, path)

      assert Permissions.effective(deny_policy, "write_file", "secret/k") == :deny
      # outside the deny entry: back to the class default (allow since
      # the 2026-09-15 amendment)
      assert Permissions.effective(deny_policy, "write_file", "other") == :allow
    end
  end

  describe "resolve_decisions through a live session process" do
    # These tests call the private machinery via a real session whose
    # policy forces an interruption; the interrupted state and decide/2
    # round-trip are what 2b guarantees. The LLM part is stubbed by
    # interrupting the session directly through the same code path the
    # gate uses: process a tool-call event batch via Session.gate/2.
    test "approve executes, reject does not, edit rewrites args", %{policy: policy} do
      id = "dec-live-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          policy: policy
        )

      calls = [
        tool_call("c1", "write_file", %{"path" => "approved.txt", "content" => "yes"}),
        tool_call("c2", "write_file", %{"path" => "rejected.txt", "content" => "no"}),
        tool_call("c3", "write_file", %{"path" => "orig.txt", "content" => "original"})
      ]

      :ok = Session.debug_gate(id, calls)
      {:ok, state} = Session.state(id)
      assert state.status == :interrupted

      decisions = [
        %{id: "c1", decision: :approve},
        %{id: "c2", decision: :reject},
        %{id: "c3", decision: {:edit, %{"path" => "edited.txt", "content" => "edited!"}}}
      ]

      {:ok, state2} = Session.decide(id, decisions)

      assert state2.status == :idle
      assert File.read!(Path.join(@tmp_root, "approved.txt")) == "yes"
      refute File.exists?(Path.join(@tmp_root, "rejected.txt"))
      assert File.read!(Path.join(@tmp_root, "edited.txt")) == "edited!"
      refute File.exists?(Path.join(@tmp_root, "orig.txt"))

      # the assistant tool-call message that goes back to the model must
      # carry the REAL arguments (original for approve/reject, edited for
      # edit) — a hardcoded "{}" erased every prior call's args from the
      # model's view (live bug: 12-round loop of empty-args shell calls,
      # "required :command option not found")
      assistant = Enum.find(state2.context.messages, fn m -> m.tool_calls != nil end)

      args_by_id =
        Map.new(assistant.tool_calls, fn tc ->
          {tc.id, tc.function.arguments}
        end)

      # binary JSON or a decoded map, depending on the call shape; decode
      # for comparison (encoded key order is sorted)
      decoded =
        Map.new(args_by_id, fn {id, args} ->
          {id, if(is_binary(args), do: Jason.decode!(args), else: args)}
        end)

      assert decoded["c1"] == %{"path" => "approved.txt", "content" => "yes"}
      assert decoded["c2"] == %{"path" => "rejected.txt", "content" => "no"}
      assert decoded["c3"] == %{"path" => "edited.txt", "content" => "edited!"}
    end

    test "rejected-only batch feeds the rejection back to the model", %{policy: policy} do
      id = "dec-live-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          policy: policy
        )

      :ok =
        Session.debug_gate(id, [
          tool_call("r1", "write_file", %{"path" => "x.txt", "content" => "x"})
        ])

      {:ok, state} = Session.decide(id, [%{id: "r1", decision: :reject}])

      assert state.status == :idle

      # last message is the tool result with the rejection
      last = state.context |> ReqLLM.Context.to_list() |> List.last()
      assert last.role == :tool
      assert text_of(last) =~ "rejected"
    end
  end

  defp text_of(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t || ""
      _ -> ""
    end)
  end

  defp text_of(%ReqLLM.Message{content: c}) when is_binary(c), do: c

  test "batch approve: one decision per id approves the whole parallel batch", %{policy: policy} do
    id = "dec-batch-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: id,
        scope_root: @tmp_root,
        policy: policy
      )

    calls = [
      tool_call("p1", "write_file", %{"path" => "b1.txt", "content" => "1"}),
      tool_call("p2", "write_file", %{"path" => "b2.txt", "content" => "2"}),
      tool_call("p3", "write_file", %{"path" => "b3.txt", "content" => "3"})
    ]

    :ok = Session.debug_gate(id, calls)
    {:ok, state} = Session.state(id)
    assert state.status == :interrupted
    assert length(state.pending_tool_calls) == 3

    # the TUI's y maps EVERY pending id to :approve — one keystroke,
    # whole batch
    decisions =
      Enum.map(state.pending_tool_calls, fn %{id: pid} -> %{id: pid, decision: :approve} end)

    {:ok, state2} = Session.decide(id, decisions)
    assert state2.status == :idle
    assert File.read!(Path.join(@tmp_root, "b1.txt")) == "1"
    assert File.read!(Path.join(@tmp_root, "b2.txt")) == "2"
    assert File.read!(Path.join(@tmp_root, "b3.txt")) == "3"
  end
end
