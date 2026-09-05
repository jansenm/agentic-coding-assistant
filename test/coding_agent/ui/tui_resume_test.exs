defmodule CodingAgent.UI.TuiResumeTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session.Store
  alias CodingAgent.UI.Tui

  # User report: 'mix tui --resume <id>' started the session but the
  # old messages were not visible — the transcript was seeded empty
  # regardless of the restored context. Fixed: restored history renders
  # (user/assistant/tool lines; system prompts hidden; compaction
  # summaries surface as an info line).

  test "resumed sessions render their historical messages" do
    sid = "resume-hist-#{System.unique_integer()}"

    # build a persisted session with a real conversation
    context =
      ReqLLM.Context.new()
      |> ReqLLM.Context.append(ReqLLM.Context.system("framework prompt"))
      |> ReqLLM.Context.append(ReqLLM.Context.user("remember the codeword BANANA"))
      |> ReqLLM.Context.append(
        ReqLLM.Context.tool_result_message("shell", "c1", "exit 0\n--- output ---\nBANANA noted")
      )
      |> ReqLLM.Context.append(ReqLLM.Context.assistant("Codeword noted."))

    :ok =
      Store.save(
        CodingAgent.Core.Session.State.new(
          id: sid,
          context: context,
          model: "ollama:test-model",
          status: :idle
        )
      )

    pid =
      start_supervised!(
        {Tui, [name: nil, test_mode: {80, 24}, resume_id: sid, scope_root: File.cwd!()]}
      )

    wait_until(fn ->
      :sys.get_state(pid).user_state.transcript != []
    end)

    transcript = :sys.get_state(pid).user_state.transcript

    assert {:user, "remember the codeword BANANA"} in transcript
    assert {:assistant, "Codeword noted."} in transcript

    tool_line = Enum.find(transcript, fn {role, _} -> role == :tool end)
    assert tool_line != nil and elem(tool_line, 1) =~ "shell"

    # the framework system prompt stays hidden
    refute Enum.any?(transcript, fn {_r, t} -> t =~ "framework prompt" end)
  end

  test "a compacted session surfaces the summary as an info line" do
    sid = "resume-compacted-#{System.unique_integer()}"

    summary = %ReqLLM.Message{
      role: :user,
      content: [
        ReqLLM.Message.ContentPart.text(
          "[Conversation summary — earlier messages were compacted]\nSummary text..."
        )
      ]
    }

    context =
      ReqLLM.Context.new()
      |> ReqLLM.Context.append(ReqLLM.Context.system("framework prompt"))
      |> ReqLLM.Context.append(summary)
      |> ReqLLM.Context.append(ReqLLM.Context.assistant("after compaction"))

    :ok =
      Store.save(
        CodingAgent.Core.Session.State.new(
          id: sid,
          context: context,
          model: "ollama:test-model",
          status: :idle
        )
      )

    pid =
      start_supervised!(
        {Tui, [name: nil, test_mode: {80, 24}, resume_id: sid, scope_root: File.cwd!()]}
      )

    wait_until(fn -> :sys.get_state(pid).user_state.transcript != [] end)

    transcript = :sys.get_state(pid).user_state.transcript
    assert Enum.any?(transcript, fn {role, t} -> role == :info and t =~ "compacted" end)
    assert {:assistant, "after compaction"} in transcript
  end

  defp wait_until(fun, tries \\ 150) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      wait_until(fun, tries - 1)
    end
  end
end
