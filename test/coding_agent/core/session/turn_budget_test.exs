defmodule CodingAgent.Core.Session.TurnBudgetTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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
      log =
        capture_log(fn ->
          :ok =
            Session.debug_gate(
              id,
              [tool_call("w1", "write_file", %{"path" => "never.txt", "content" => "x"})],
              rounds: 100
            )
        end)

      # the trip is a logged event, not a silent one: the wrap-up says so
      assert log =~ "tool-round budget reached: 100"

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

  describe "the interactive budget prompt (ADR 025)" do
    test "an interactive trip PAUSES and holds the round instead of wrapping up" do
      id = "budget-ask-#{System.unique_integer()}"
      start(id, interactive: true)

      log =
        capture_log(fn ->
          :ok =
            Session.debug_gate(
              id,
              [tool_call("h1", "write_file", %{"path" => "held.txt", "content" => "x"})],
              rounds: 100
            )
        end)

      assert log =~ "tool-round budget reached: 100 (asking)"
      {:ok, state} = Session.state(id)
      assert state.status == :interrupted
      assert state.budget_pause.budget == 100

      held_ids = Enum.map(state.budget_pause.calls, fn c -> c.id end)
      assert held_ids == ["h1"]
      refute File.exists?(Path.join(@tmp_root, "held.txt")), "the held round must not run yet"
    end

    test "continue runs the held round under a fresh budget" do
      id = "budget-cont-#{System.unique_integer()}"
      start(id, interactive: true)

      log =
        capture_log(fn ->
          :ok =
            Session.debug_gate(
              id,
              [tool_call("h2", "write_file", %{"path" => "cont.txt", "content" => "y"})],
              rounds: 100
            )

          {:ok, _} = Session.budget_decision(id, :continue)
        end)

      # both halves are logged: the question, then the wrap-up of the round
      # that ran under the fresh budget
      assert log =~ "tool-round budget reached: 100 (asking)"
      assert log =~ "tool-round budget reached: 100"
      {:ok, state} = Session.state(id)

      assert File.read!(Path.join(@tmp_root, "cont.txt")) == "y"
      assert state.budget_pause == nil
      assert state.tool_rounds <= 1
    end

    test "stop discards the held round and wraps up" do
      id = "budget-stop-#{System.unique_integer()}"
      start(id, interactive: true)

      log =
        capture_log(fn ->
          :ok =
            Session.debug_gate(
              id,
              [tool_call("h3", "write_file", %{"path" => "stopped.txt", "content" => "z"})],
              rounds: 100
            )

          {:ok, _} = Session.budget_decision(id, :stop)
        end)

      assert log =~ "tool-round budget reached: 100"
      {:ok, state} = Session.state(id)

      refute File.exists?(Path.join(@tmp_root, "stopped.txt")), "stop must discard the round"
      assert state.budget_pause == nil
      assert state.status == :idle
    end

    test "a budget_decision outside a pause is refused" do
      id = "budget-none-#{System.unique_integer()}"
      start(id, interactive: true)

      assert {:error, {:not_at_budget, :idle}} = Session.budget_decision(id, :continue)
    end
  end

  describe "the wrap-up request (ADR 025)" do
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

    test "wire_request/1 rides the tail with the context-budget block" do
      id = "budget-wire3-#{System.unique_integer()}"
      start(id)
      {:ok, s} = Session.state(id)

      {:ok, _input, _opts, ctx} = Session.wire_request(s)

      text =
        ctx
        |> ReqLLM.Context.to_list()
        |> List.last()
        |> Map.fetch!(:content)
        |> Enum.map_join("", &(&1.text || ""))

      assert text =~ "Context budget:"
      assert text =~ "there is room"
    end

    test "wire_request/1 passes the approaching threshold the human's note uses" do
      id = "budget-wire4-#{System.unique_integer()}"
      start(id)
      {:ok, s} = Session.state(id)

      # the band advice is only reachable when the session supplies `warn_at`
      # (ADR 040 amendment): set the projected size into the band and see the
      # sentence, so the wiring between `ContextBudget.from_state/2` and
      # `Prompt` is pinned rather than assumed — the struct makes a missing
      # field a compile error, but not a WRONG field.
      soft = CodingAgent.Core.Session.Compactor.soft_limit(s)
      warn_at = CodingAgent.Core.Session.Compactor.warn_threshold(s)
      assert warn_at < soft

      in_band = %{
        s
        | usage: %{s.usage | last_input_tokens: warn_at + div(soft - warn_at, 2)}
      }

      {:ok, _input, _opts, ctx} = Session.wire_request(in_band)
      [%ReqLLM.Message{role: :system} = sys | _] = ReqLLM.Context.to_list(ctx)
      text = Enum.map_join(sys.content, "", &(&1.text || ""))

      assert text =~ "approaching the soft line"
      refute text =~ "Soft line "
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
