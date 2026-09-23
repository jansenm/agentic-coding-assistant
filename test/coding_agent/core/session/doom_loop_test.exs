defmodule CodingAgent.Core.Session.DoomLoopTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session

  @tmp_root System.tmp_dir!() |> Path.join("agent-doom-#{System.unique_integer()}")

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

  defp start(id, opts) do
    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        Keyword.merge(
          [id: id, scope_root: @tmp_root, policy: Permissions.load(nil, nil), test_mode: true],
          opts
        )
      )
  end

  # A read-only call the policy allows without a dialog, so the doom guard
  # is the only thing that can pause.
  defp read_call(id), do: tool_call(id, "read_file", %{"path" => "same.txt"})

  describe "the doom-loop guard (ADR 026)" do
    test "three identical calls pause an interactive session" do
      id = "doom-pause-#{System.unique_integer()}"
      start(id, interactive: true)

      :ok = Session.debug_gate(id, [read_call("d1")])
      :ok = Session.debug_gate(id, [read_call("d2")])
      :ok = Session.debug_gate(id, [read_call("d3")])

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted
      assert state.doom_pause.tool == "read_file"
      assert length(state.doom_pause.calls) == 1
    end

    test "one round with 3 parallel identical calls does NOT trip (round window)" do
      id = "doom-par-#{System.unique_integer()}"
      start(id, interactive: true)

      :ok =
        Session.debug_gate(id, [
          read_call("p1"),
          read_call("p2"),
          read_call("p3")
        ])

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      assert state.doom_pause == nil
    end

    test "two identical calls do NOT pause (below the window)" do
      id = "doom-under-#{System.unique_integer()}"
      start(id, interactive: true)

      :ok = Session.debug_gate(id, [read_call("u1")])
      :ok = Session.debug_gate(id, [read_call("u2")])

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      assert state.doom_pause == nil
    end

    test "three DIFFERENT calls do NOT pause" do
      id = "doom-diff-#{System.unique_integer()}"
      start(id, interactive: true)

      :ok = Session.debug_gate(id, [tool_call("x1", "read_file", %{"path" => "a.txt"})])
      :ok = Session.debug_gate(id, [tool_call("x2", "read_file", %{"path" => "b.txt"})])
      :ok = Session.debug_gate(id, [tool_call("x3", "read_file", %{"path" => "c.txt"})])

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      assert state.doom_pause == nil
    end

    test "same tool but DIFFERENT args does NOT pause" do
      id = "doom-args-#{System.unique_integer()}"
      start(id, interactive: true)

      :ok = Session.debug_gate(id, [tool_call("a1", "read_file", %{"path" => "a.txt"})])
      :ok = Session.debug_gate(id, [tool_call("a2", "read_file", %{"path" => "b.txt"})])
      :ok = Session.debug_gate(id, [tool_call("a3", "read_file", %{"path" => "a.txt"})])

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      assert state.doom_pause == nil
    end

    test "continue runs the repeated round anyway" do
      id = "doom-cont-#{System.unique_integer()}"
      start(id, interactive: true)

      for i <- 1..3 do
        :ok = Session.debug_gate(id, [read_call("c#{i}")])
      end

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted

      {:ok, _} = Session.doom_decision(id, :continue)
      {:ok, state} = Session.state(id)

      assert state.doom_pause == nil
      # the held round ran: the context now has 3 real tool results, and
      # none of them is the synthetic steer text
      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      refute text =~ "repeated identical call rejected"
    end

    test "reject steers: the held round is answered with a synthetic result" do
      id = "doom-rej-#{System.unique_integer()}"
      start(id, interactive: true)

      for i <- 1..3 do
        :ok = Session.debug_gate(id, [read_call("r#{i}")])
      end

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted

      {:ok, _} = Session.doom_decision(id, :reject)
      {:ok, state} = Session.state(id)

      assert state.doom_pause == nil

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "repeated identical call rejected"
    end

    test "a doom decision outside a pause is refused" do
      id = "doom-none-#{System.unique_integer()}"
      start(id, interactive: true)
      assert {:error, {:not_at_doom, :idle}} = Session.doom_decision(id, :reject)
    end

    test "a non-interactive session steers silently instead of pausing" do
      id = "doom-silent-#{System.unique_integer()}"
      start(id, interactive: false)

      for i <- 1..3 do
        :ok = Session.debug_gate(id, [read_call("s#{i}")])
      end

      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      assert state.doom_pause == nil

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.map_join("\n", &message_text/1)

      assert text =~ "repeated identical call rejected"
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
