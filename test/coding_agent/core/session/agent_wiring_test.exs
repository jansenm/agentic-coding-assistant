defmodule CodingAgent.Core.Session.AgentWiringTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session

  @tmp_root System.tmp_dir!() |> Path.join("agent-wiring-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  defp start(id, opts) do
    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        Keyword.merge([id: id, scope_root: @tmp_root, test_mode: true], opts)
      )
  end

  test "no :agent keeps the pre-agent behaviour (nil agent, default policy)" do
    start("wiring-none", [])
    {:ok, state} = Session.state("wiring-none")

    assert state.agent == nil
    assert Permissions.enabled(state.policy) == :default
    assert Permissions.disabled(state.policy) == []
  end

  test "a named agent is resolved and recorded on the state" do
    start("wiring-build", agent: "build")
    {:ok, state} = Session.state("wiring-build")

    assert state.agent.name == "build"
    assert state.agent.mode == :primary
  end

  test "the plan agent removes the write tools but keeps a read-only shell" do
    start("wiring-plan", agent: "plan")
    {:ok, state} = Session.state("wiring-plan")

    assert state.agent.name == "plan"

    # disallowedTools: edit, write_file, git — shell stays, but read-only
    disabled = Permissions.disabled(state.policy)
    assert "edit" in disabled
    assert "write_file" in disabled
    assert "git" in disabled
    refute "shell" in disabled
    assert Permissions.shell_mode(state.policy) == :ro
  end

  test "the plan agent keeps read tools and a shell, but no write tools" do
    start("wiring-plan-tools", agent: "plan")
    {:ok, state} = Session.state("wiring-plan-tools")

    tools = CodingAgent.Core.Tools.all(%{root: @tmp_root})
    disabled = Permissions.disabled(state.policy)
    visible = Enum.reject(tools, &(&1.name in disabled))
    names = Enum.map(visible, & &1.name)

    refute "edit" in names
    refute "write_file" in names
    refute "git" in names
    assert "shell" in names
    assert "read_file" in names
    assert "grep" in names
    assert "glob" in names
  end

  test "the agent prompt is composed onto the framework prompt" do
    start("wiring-prompt", agent: "plan")
    {:ok, state} = Session.state("wiring-prompt")

    system =
      state.context
      |> ReqLLM.Context.to_list()
      |> Enum.find(&(&1.role == :system))

    text = system_text(system)
    assert text =~ "coding assistant"
    assert text =~ "planning agent"
  end

  test "an unknown agent name is a hard error" do
    assert {:error, _} =
             CodingAgent.Core.Session.Supervisor.start_session(
               id: "wiring-bogus",
               scope_root: @tmp_root,
               test_mode: true,
               agent: "does-not-exist"
             )
  end

  describe "set_agent/2 (ADR 018 next-slot switch)" do
    test "switches the agent and its tool restrictions" do
      start("switch-a", agent: "build")
      assert {:ok, s} = Session.set_agent("switch-a", "plan")

      assert s.agent.name == "plan"
      assert "edit" in Permissions.disabled(s.policy)
      assert Permissions.shell_mode(s.policy) == :ro
    end

    test "switching back does not compound restrictions" do
      start("switch-b", agent: "plan")
      {:ok, _} = Session.set_agent("switch-b", "build")
      {:ok, s} = Session.set_agent("switch-b", "plan")

      # exactly plan's three denied tools, not plan-on-plan accumulation
      assert Enum.sort(Permissions.disabled(s.policy)) == ["edit", "git", "write_file"]
      assert Permissions.shell_mode(s.policy) == :ro
    end

    test "clearing the agent restores the base policy" do
      start("switch-c", agent: "plan")
      {:ok, s} = Session.set_agent("switch-c", nil)

      assert s.agent == nil
      assert Permissions.disabled(s.policy) == []
      # the read-only shell was the DEFINITION's, not the session's
      assert Permissions.shell_mode(s.policy) == :rw
    end

    test "the system prompt follows the agent" do
      start("switch-d", agent: "build")
      {:ok, s} = Session.set_agent("switch-d", "plan")

      assert system_text_of(s) =~ "planning agent"
    end

    test "an unknown agent returns an error and leaves the state alone" do
      start("switch-e", agent: "build")
      assert {:error, {:unknown_agent, "nope", _}} = Session.set_agent("switch-e", "nope")

      {:ok, s} = Session.state("switch-e")
      assert s.agent.name == "build"
    end
  end

  describe "effective_model/1 (ADR 017 model field)" do
    test "an agent without a model uses the session model" do
      start("model-none", agent: "build")
      {:ok, s} = Session.state("model-none")

      refute s.agent.model
      assert Session.effective_model(s) == s.model
    end

    test "an agent with its own model wins over the session model" do
      # build a state directly: the loader only reads files, so this is
      # the unit-level check of the precedence
      agent = %CodingAgent.Core.Agent{
        name: "cheap",
        prompt: "p",
        source: "test",
        model: "ollama:tiny"
      }

      state = %CodingAgent.Core.Session.State{
        id: "m",
        context: ReqLLM.Context.new(),
        model: "ollama_cloud:glm",
        status: :idle,
        agent: agent
      }

      assert Session.effective_model(state) == "ollama:tiny"
    end

    test "no agent at all uses the session model" do
      state = %CodingAgent.Core.Session.State{
        id: "m",
        context: ReqLLM.Context.new(),
        model: "ollama_cloud:glm",
        status: :idle,
        agent: nil
      }

      assert Session.effective_model(state) == "ollama_cloud:glm"
    end
  end

  describe "model switch recomposes the model-selected prompt (ADR 024)" do
    test "set_model/2 swaps the framework prompt for the new model" do
      # start on a non-Claude model, then switch to a Claude id: the
      # framework prompt must follow the model, not stay on the old one.
      start("recompose-a", model: "ollama:qwen3")
      {:ok, before} = Session.state("recompose-a")
      refute system_text_of(before) =~ "Professional objectivity"

      :ok = Session.set_model("recompose-a", "anthropic:claude-sonnet-4")
      {:ok, after_switch} = Session.state("recompose-a")

      assert after_switch.model == "anthropic:claude-sonnet-4"
      assert system_text_of(after_switch) =~ "Professional objectivity"
      # the system message actually changed (not the old text left in place)
      refute system_text_of(before) == system_text_of(after_switch)
      refute system_text_of(before) =~ "Professional objectivity"
    end

    test "a model switch keeps the active agent's body" do
      start("recompose-b", model: "ollama:qwen3", agent: "plan")
      :ok = Session.set_model("recompose-b", "anthropic:claude-sonnet-4")
      {:ok, s} = Session.state("recompose-b")

      # both the new model prompt AND the plan role survive
      assert system_text_of(s) =~ "Professional objectivity"
      assert system_text_of(s) =~ "planning agent"
    end

    test "an override still wins after a model switch" do
      start("recompose-c", model: "ollama:qwen3", system_prompt: "MY-OVERRIDE")
      :ok = Session.set_model("recompose-c", "anthropic:claude-sonnet-4")
      {:ok, s} = Session.state("recompose-c")

      assert system_text_of(s) =~ "MY-OVERRIDE"
      refute system_text_of(s) =~ "Professional objectivity"
    end
  end

  describe "wire_request/1 (ADR 024 assembly)" do
    test "appends the environment block on the wire, not in the stored context" do
      start("wire-env", model: "ollama:qwen3")
      {:ok, s} = Session.state("wire-env")

      {:ok, _model_input, _opts, wire_context} = Session.wire_request(s)

      wire_system = wire_context |> ReqLLM.Context.to_list() |> hd()
      assert system_text(wire_system) =~ "<env>"
      assert system_text(wire_system) =~ "Model: ollama:qwen3"

      # the session's stored context is untouched
      refute system_text_of(s) =~ "<env>"
    end

    test "the block names the agent and the store the session is using (P2)" do
      start("wire-env-agent", model: "ollama:qwen3", agent: "build")
      {:ok, s} = Session.state("wire-env-agent")

      {:ok, _input, _opts, ctx} = Session.wire_request(s)
      text = ctx |> ReqLLM.Context.to_list() |> hd() |> system_text()

      # the agent row is the session's own definition, not a re-derivation
      assert text =~ "Agent: build"
      # the store row names the real active database (checkpoint refs are
      # store-namespaced, so history is read against THIS one)
      assert text =~ "Store: #{CodingAgent.Core.Config.store_path()}"
    end

    test "a read-only plan session says its agent name in the environment block" do
      start("wire-env-plan", model: "ollama:qwen3", agent: "plan")
      {:ok, s} = Session.state("wire-env-plan")

      {:ok, _input, _opts, ctx} = Session.wire_request(s)
      text = ctx |> ReqLLM.Context.to_list() |> hd() |> system_text()

      assert s.agent.name == "plan"
      assert text =~ "Agent: plan"
    end

    test "a per-agent temperature rides the request opts" do
      start("wire-temp", model: "ollama:qwen3")

      {:ok, s} = Session.state("wire-temp")
      agent = %CodingAgent.Core.Agent{name: "cold", prompt: "p", source: "t", temperature: 0.1}
      s = %{s | agent: agent}

      {:ok, _input, opts, _ctx} = Session.wire_request(s)
      assert opts[:temperature] == 0.1
    end

    test "no agent temperature leaves the provider default (no :temperature key)" do
      start("wire-notemp", model: "ollama:qwen3")
      {:ok, s} = Session.state("wire-notemp")

      {:ok, _input, opts, _ctx} = Session.wire_request(s)
      refute Keyword.has_key?(opts, :temperature)
    end

    test "the session's reasoning effort rides the request opts (ADR 029)" do
      start("wire-effort", model: "ollama:qwen3")
      {:ok, s} = Session.state("wire-effort")
      s = %{s | reasoning_effort: :high}

      {:ok, _input, opts, _ctx} = Session.wire_request(s)
      assert opts[:reasoning_effort] == :high
    end

    test "no reasoning effort leaves the provider default (no :reasoning_effort key)" do
      start("wire-noeffort", model: "ollama:qwen3")
      {:ok, s} = Session.state("wire-noeffort")

      {:ok, _input, opts, _ctx} = Session.wire_request(s)
      refute Keyword.has_key?(opts, :reasoning_effort)
    end

    test "a config.toml reasoning_effort reaches both the state and the wire (ADR 029)" do
      File.mkdir_p!(Path.join(@tmp_root, ".coding-agent"))

      File.write!(
        Path.join(@tmp_root, ".coding-agent/config.toml"),
        ~s(reasoning_effort = "low")
      )

      on_exit(fn -> File.rm_rf!(Path.join(@tmp_root, ".coding-agent")) end)

      start("wire-effort-cfg", model: "ollama:qwen3")
      {:ok, s} = Session.state("wire-effort-cfg")

      assert s.reasoning_effort == :low

      {:ok, _input, opts, _ctx} = Session.wire_request(s)
      assert opts[:reasoning_effort] == :low
    end
  end

  describe "wire_request/1 capability block (P1)" do
    test "a plan session's wire context states the missing tools and the read-only shell" do
      start("wire-cap-plan", agent: "plan")
      {:ok, s} = Session.state("wire-cap-plan")
      {:ok, _input, _opts, wire_context} = Session.wire_request(s)

      wire_system = wire_context |> ReqLLM.Context.to_list() |> hd()
      text = system_text(wire_system)

      assert text =~ "Session capabilities:"
      # plan.md's disallowedTools, named ahead of any attempt (the order
      # is the sorted registry, so match the names individually)
      assert text =~ "edit"
      assert text =~ "write_file"
      assert text =~ "git"
      # permission.shell = read_only: the capability the tool list cannot express
      assert text =~ "READ-ONLY"
      # the stored context is untouched (the per-call contract, ADR 024)
      refute system_text_of(s) =~ "Session capabilities:"
    end

    test "a default build session states the ask-tool it really has (webfetch)" do
      start("wire-cap-build", [])
      {:ok, s} = Session.state("wire-cap-build")

      # webfetch is ask-by-policy in the shipped defaults, and the block is
      # derived from the gate's own decision, so a stock session states it
      assert Session.gate_decisions(s)["webfetch"] == :ask

      {:ok, _input, _opts, wire_context} = Session.wire_request(s)
      text = wire_context |> ReqLLM.Context.to_list() |> hd() |> system_text()

      assert text =~ "Session capabilities:"
      assert text =~ "webfetch"
      assert text =~ "require the human's approval"
      # a deficit clause would be wrong here: build has every tool
      refute text =~ "unknown tool"
      refute text =~ "READ-ONLY"
    end

    test "a policy entry that asks reaches the block through the gate's decision path" do
      File.mkdir_p!(Path.join(@tmp_root, ".coding-agent"))

      File.write!(
        Path.join(@tmp_root, ".coding-agent/permissions.toml"),
        "[permissions.git]\n\"*\" = \"ask\"\n"
      )

      on_exit(fn -> File.rm_rf!(Path.join(@tmp_root, ".coding-agent")) end)

      start("wire-cap-ask", [])
      {:ok, s} = Session.state("wire-cap-ask")

      # the same call a real git call would take, through the same function
      assert Session.gate_decisions(s)["git"] == :ask

      {:ok, _input, _opts, wire_context} = Session.wire_request(s)
      text = wire_context |> ReqLLM.Context.to_list() |> hd() |> system_text()

      assert text =~ "git"
      assert text =~ "require the human's approval"
    end
  end

  defp system_text_of(state) do
    state.context
    |> ReqLLM.Context.to_list()
    |> Enum.find(&(&1.role == :system))
    |> system_text()
  end

  defp system_text(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t || ""
      _ -> ""
    end)
  end

  defp system_text(%ReqLLM.Message{content: c}) when is_binary(c), do: c
  defp system_text(_), do: ""
end
