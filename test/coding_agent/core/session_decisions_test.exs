defmodule CodingAgent.Core.Session.DecisionsTest do
  use ExUnit.Case, async: false

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
  describe "gate splitting (pure policy behavior)" do
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
      assert Permissions.effective(deny_policy, "write_file", "other") == :ask
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
end
