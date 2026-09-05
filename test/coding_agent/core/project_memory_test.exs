defmodule CodingAgent.Core.Session.ProjectMemoryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session

  @root System.tmp_dir!() |> Path.join("agent-agentsmd-#{System.unique_integer()}")

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(@root)
    on_exit(fn -> File.rm_rf!(@root) end)
    %{root: @root}
  end

  test "AGENTS.md content lands in the system prompt", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), """
    Always answer in haiku. Prefer tabs over spaces.
    """)

    id = "pm-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(id: id, scope_root: root, test_mode: true)

    {:ok, state} = Session.state(id)
    [system | _] = ReqLLM.Context.to_list(state.context)
    text = text_of(system)

    assert text =~ "Project memory (AGENTS.md)"
    assert text =~ "Prefer tabs over spaces"
    # the framework prompt is still there
    assert text =~ "coding assistant"
  end

  test "no AGENTS.md: system prompt unchanged", %{root: root} do
    id = "pm-none-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(id: id, scope_root: root, test_mode: true)

    {:ok, state} = Session.state(id)
    [system | _] = ReqLLM.Context.to_list(state.context)
    refute text_of(system) =~ "Project memory"
  end

  @tag capture_log: true
  test "oversized AGENTS.md truncates instead of failing", %{root: root} do
    # the truncation path logs a warning by design — capture it here
    File.write!(Path.join(root, "AGENTS.md"), String.duplicate("x", 100_000))

    id = "pm-big-#{System.unique_integer()}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(id: id, scope_root: root, test_mode: true)

    {:ok, state} = Session.state(id)
    [system | _] = ReqLLM.Context.to_list(state.context)
    text = text_of(system)
    # truncated to the 64 KiB window but still a working system prompt
    assert text =~ "Project memory (AGENTS.md)"
    assert byte_size(text) < 100_000
  end

  defp text_of(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t || ""
      _ -> ""
    end)
  end

  defp text_of(%ReqLLM.Message{content: c}) when is_binary(c), do: c
end
