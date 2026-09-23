defmodule CodingAgent.Core.Session.TurnBudgetTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Session.State

  @tmp_root System.tmp_dir!() |> Path.join("agent-budget-#{System.unique_integer()}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    :ok
  end

  defp tool_call(id, name, args), do: %{id: id, name: name, arguments: args}

  defp start(id, opts \\ []) do
    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        Keyword.merge(
          [id: id, scope_root: @tmp_root, policy: Permissions.load(nil, nil), test_mode: true],
          opts
        )
      )
  end

  describe "State.tool_budget/1 (ADR 025)" do
    test "an agent's max_turns overrides the session budget" do
      state = %State{
        id: "b",
        context: ReqLLM.Context.new(),
        model: "m",
        status: :idle,
        agent: %CodingAgent.Core.Agent{name: "a", prompt: "p", source: "t", max_turns: 7},
        max_tool_rounds: 100
      }

      assert State.tool_budget(state) == 7
    end

    test "without an agent budget, the session value stands" do
      state = %State{
        id: "b",
        context: ReqLLM.Context.new(),
        model: "m",
        status: :idle,
        max_tool_rounds: 42
      }

      assert State.tool_budget(state) == 42
    end

    test "both unset resolves to nil (the caller falls back to the app default)" do
      state = %State{id: "b", context: ReqLLM.Context.new(), model: "m", status: :idle}
      assert State.tool_budget(state) == nil
    end
  end

  describe "the budget trip wraps up instead of failing (ADR 025)" do
    test "a trip ends :idle, discards the round's calls, and records the summary request" do
      id = "budget-wrap-#{System.unique_integer()}"
      start(id)

      # a write the policy WOULD allow (so nothing else can explain the
      # file's absence)
      :ok =
        Session.debug_gate(
          id,
          [tool_call("w1", "write_file", %{"path" => "never.txt", "content" => "x"})],
          rounds: 100
        )

      {:ok, state} = Session.state(id)

      assert state.status == :idle, "a budget trip must not fail the turn"
      assert state.last_error == nil

      refute File.exists?(Path.join(@tmp_root, "never.txt")),
             "the round's calls must be discarded"

      # the wrap-up instruction is in the context
      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "tool-round budget"
      assert text =~ "Respond with text only"
    end

    test "below the budget the round proceeds normally (no wrap-up)" do
      id = "budget-under-#{System.unique_integer()}"
      start(id)

      :ok =
        Session.debug_gate(
          id,
          [tool_call("w2", "write_file", %{"path" => "ok.txt", "content" => "1"})],
          rounds: 0
        )

      {:ok, state} = Session.state(id)
      # the normal gate path ran the write (a trip would have discarded it)
      assert File.read!(Path.join(@tmp_root, "ok.txt")) == "1"
      refute state.last_error
    end
  end

  describe "the wrap-up request withholds tools (ADR 025)" do
    test "wire_request/2 with tools: [] sends an empty tool list" do
      id = "budget-wire-#{System.unique_integer()}"
      start(id)
      {:ok, s} = Session.state(id)

      {:ok, _input, opts, _ctx} = Session.wire_request(s, tools: [])
      assert opts[:tools] == []
    end

    test "the default wire_request/1 still offers the toolset" do
      id = "budget-wire2-#{System.unique_integer()}"
      start(id)
      {:ok, s} = Session.state(id)

      {:ok, _input, opts, _ctx} = Session.wire_request(s)
      refute opts[:tools] == []
    end
  end

  defp message_text(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp message_text(%ReqLLM.Message{content: t}) when is_binary(t), do: t
  defp message_text(_), do: ""
end
