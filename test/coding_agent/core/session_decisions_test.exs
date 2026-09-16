defmodule CodingAgent.Core.Session.DecisionsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.Store

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

    test "debug_gate refuses a non-test session (codereview §11)" do
      # a live session must never be silently flipped into test mode by
      # the test hook; it used to set test_mode: true unconditionally,
      # so the next real turn raised "reached call_llm"
      id = "notest-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root
        )

      assert {:error, :not_test_mode} =
               Session.debug_gate(id, [
                 tool_call("w1", "write_file", %{"path" => "x.txt", "content" => "x"})
               ])

      # the session stays untouched: still not test_mode, nothing ran
      {:ok, state} = Session.state(id)
      refute state.test_mode
      refute File.exists?(Path.join(@tmp_root, "x.txt"))
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
          policy: policy,
          test_mode: true
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
          policy: policy,
          test_mode: true
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
        policy: policy,
        test_mode: true
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

  test "a stop before a tool round skips execution (synthetic results)" do
    id = "dec-stop-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: id,
        scope_root: @tmp_root,
        policy: Permissions.load(nil, nil),
        test_mode: true
      )

    # the user pressed esc just before the auto round ran
    CodingAgent.Core.Interrupt.request(id)

    :ok =
      Session.debug_gate(id, [
        tool_call("s1", "write_file", %{"path" => "never.txt", "content" => "x"})
      ])

    # the tool never ran, even though the policy would have allowed it
    refute File.exists?(Path.join(@tmp_root, "never.txt"))
    CodingAgent.Core.Interrupt.clear(id)
  end

  # codereview §2: the tool round must reach the model as ONE canonical
  # exchange — the assistant message declares every application call of
  # the round, and every result has a declaring call. Bare tool results
  # with no preceding assistant message are orphaned and strict
  # OpenAI-compatible backends reject or mis-associate them by
  # tool_call_id.
  describe "atomic tool-round exchange (codereview §2)" do
    test "an all-auto round declares the assistant tool-call message, not orphaned results" do
      id = "round-auto-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          policy: Permissions.load(nil, nil),
          test_mode: true
        )

      :ok =
        Session.debug_gate(id, [
          tool_call("a1", "write_file", %{"path" => "auto-round.txt", "content" => "x"})
        ])

      {:ok, state} = Session.state(id)
      assert_round_shape(state.context, [["a1"]], ["a1"])
    end

    test "a mixed round declares all calls once decided, in call order" do
      toml = Path.join(@tmp_root, "mixed.toml")

      File.write!(toml, """
      [permissions.write_file]
      "*" = "ask"
      """)

      id = "round-mixed-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          policy: Permissions.load(nil, toml),
          test_mode: true
        )

      # read_file auto-allows, write_file asks -> mixed round
      :ok =
        Session.debug_gate(id, [
          tool_call("r1", "read_file", %{"path" => "nope.txt"}),
          tool_call("w1", "write_file", %{"path" => "mixed.txt", "content" => "x"})
        ])

      # held back until the human answers: no half-formed exchange yet
      {:ok, held} = Session.state(id)
      assert held.status == :interrupted
      refute Enum.any?(ReqLLM.Context.to_list(held.context), &(&1.role == :tool))

      {:ok, state} = Session.decide(id, [%{id: "w1", decision: :approve}])

      # both calls declared by ONE assistant message, results in order
      assert_round_shape(state.context, [["r1", "w1"]], ["r1", "w1"])
    end

    test "a policy deny never parks as an approvable pending call" do
      toml = Path.join(@tmp_root, "deny-round.toml")

      File.write!(toml, """
      [permissions.write_file]
      "secret/**" = "deny"
      """)

      id = "round-deny-#{System.unique_integer()}"
      File.mkdir_p!(Path.join(@tmp_root, "secret"))

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          policy: Permissions.load(nil, toml),
          test_mode: true
        )

      :ok =
        Session.debug_gate(id, [
          tool_call("d1", "write_file", %{"path" => "secret/k", "content" => "x"})
        ])

      {:ok, state} = Session.state(id)
      # ADR 010: deny = "never even ask" — no pause, no approve path
      refute state.status == :interrupted
      assert state.pending_tool_calls == []
      refute File.exists?(Path.join(@tmp_root, "secret/k"))

      # the model gets a denial result in the same round
      assert_round_shape(state.context, [["d1"]], ["d1"])
      [tool] = tool_messages(state.context)
      assert text_of(tool) =~ "permission denied"
    end

    test "an edited call's args reach the assistant message; results stay ordered" do
      toml = Path.join(@tmp_root, "edit-round.toml")

      File.write!(toml, """
      [permissions.write_file]
      "*" = "ask"
      """)

      id = "round-edit-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          policy: Permissions.load(nil, toml),
          test_mode: true
        )

      :ok =
        Session.debug_gate(id, [
          tool_call("e1", "write_file", %{"path" => "orig.txt", "content" => "original"}),
          tool_call("e2", "write_file", %{"path" => "keep.txt", "content" => "keep"})
        ])

      {:ok, state} =
        Session.decide(id, [
          %{id: "e1", decision: {:edit, %{"path" => "edited.txt", "content" => "edited!"}}},
          %{id: "e2", decision: :reject}
        ])

      assert_round_shape(state.context, [["e1", "e2"]], ["e1", "e2"])

      assert File.read!(Path.join(@tmp_root, "edited.txt")) == "edited!"
      refute File.exists?(Path.join(@tmp_root, "orig.txt"))

      assistant = Enum.find(ReqLLM.Context.to_list(state.context), & &1.tool_calls)
      args = args_by_id(assistant)

      assert args["e1"] == %{"path" => "edited.txt", "content" => "edited!"}
      assert args["e2"] == %{"path" => "keep.txt", "content" => "keep"}
    end

    test "a gate-parked round survives a cold restart and completes" do
      toml = Path.join(@tmp_root, "resume-round.toml")

      File.write!(toml, """
      [permissions.write_file]
      "*" = "ask"
      """)

      id = "round-resume-#{System.unique_integer()}"
      File.write!(Path.join(@tmp_root, "resume-existing.txt"), "was here")

      {:ok, pid} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          policy: Permissions.load(nil, toml),
          test_mode: true
        )

      # mixed round: the read auto-runs, the write parks
      :ok =
        Session.debug_gate(id, [
          tool_call("r1", "read_file", %{"path" => "resume-existing.txt"}),
          tool_call("w1", "write_file", %{"path" => "resume-new.txt", "content" => "new"})
        ])

      {:ok, persisted} = Store.load(id)
      assert persisted.status == :interrupted
      assert persisted.pending_round_results != []

      # cold restart, exactly the fields the resume paths forward
      GenServer.stop(pid)

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          context: persisted.context,
          model: persisted.model,
          scope_root: @tmp_root,
          policy: persisted.policy,
          test_mode: true,
          status: persisted.status,
          pending_tool_calls: persisted.pending_tool_calls,
          pending_round_calls: persisted.pending_round_calls,
          pending_round_results: persisted.pending_round_results
        )

      {:ok, resumed} = Session.state(id)
      assert resumed.status == :interrupted
      assert Enum.map(resumed.pending_tool_calls, & &1.id) == ["w1"]

      # completing the round after the restart keeps the auto half and
      # yields ONE exchange with both calls declared
      {:ok, state} = Session.decide(id, [%{id: "w1", decision: :approve}])
      assert state.status == :idle
      assert_round_shape(state.context, [["r1", "w1"]], ["r1", "w1"])
      assert File.read!(Path.join(@tmp_root, "resume-new.txt")) == "new"
    end
  end

  # codereview §3: [tools] enabled is a real whitelist.
  describe "[tools] enabled enforcement (codereview §3)" do
    test "a disabled tool is absent from the registry and never executes" do
      toml = Path.join(@tmp_root, "enabled.toml")

      File.write!(toml, """
      [tools]
      enabled = ["list_dir", "read_file"]
      """)

      id = "enabled-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          policy: Permissions.load(nil, toml),
          test_mode: true
        )

      # write_file is allow-by-class-default, but it is DISABLED here:
      # the model must get the unknown-tool error and the file must not
      # appear
      :ok =
        Session.debug_gate(id, [
          tool_call("w1", "write_file", %{"path" => "disabled.txt", "content" => "x"})
        ])

      {:ok, state} = Session.state(id)
      refute File.exists?(Path.join(@tmp_root, "disabled.txt"))

      assert_round_shape(state.context, [["w1"]], ["w1"])
      [tool] = tool_messages(state.context)
      assert text_of(tool) =~ "unknown tool"
      assert text_of(tool) =~ "available tools: list_dir, read_file"
    end

    test "an enabled tool still runs" do
      toml = Path.join(@tmp_root, "enabled-ok.toml")

      File.write!(toml, """
      [tools]
      enabled = ["list_dir", "read_file"]
      """)

      id = "enabled-ok-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          policy: Permissions.load(nil, toml),
          test_mode: true
        )

      :ok =
        Session.debug_gate(id, [
          tool_call("r1", "read_file", %{"path" => "missing.txt"})
        ])

      {:ok, state} = Session.state(id)
      [tool] = tool_messages(state.context)
      refute text_of(tool) =~ "unknown tool"
    end

    test "no [tools] section: the whole registry stays available" do
      id = "enabled-default-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @tmp_root,
          policy: Permissions.load(nil, nil),
          test_mode: true
        )

      :ok =
        Session.debug_gate(id, [
          tool_call("w1", "write_file", %{"path" => "default-on.txt", "content" => "x"})
        ])

      assert File.read!(Path.join(@tmp_root, "default-on.txt")) == "x"
    end
  end

  # Asserts the canonical exchange shape: every assistant tool-call
  # message (id-lists, in order) plus the tool result ids (in order),
  # with no orphan — every result id declared by an assistant message.
  defp assert_round_shape(context, tool_calls_declared, result_ids) do
    msgs = ReqLLM.Context.to_list(context)

    declared =
      msgs
      |> Enum.filter(& &1.tool_calls)
      |> Enum.map(fn m -> Enum.map(m.tool_calls, & &1.id) end)

    assert declared == tool_calls_declared

    assert Enum.map(tool_messages(context), & &1.tool_call_id) == result_ids

    all_declared = List.flatten(declared)
    assert Enum.all?(result_ids, &(&1 in all_declared))
  end

  defp tool_messages(context) do
    context |> ReqLLM.Context.to_list() |> Enum.filter(&(&1.role == :tool))
  end

  defp args_by_id(assistant) do
    Map.new(assistant.tool_calls, fn tc ->
      {tc.id, Jason.decode!(tc.function.arguments)}
    end)
  end
end
