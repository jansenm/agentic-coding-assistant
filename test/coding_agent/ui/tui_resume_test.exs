defmodule CodingAgent.UI.TuiResumeTest do
  use CodingAgent.TuiCase, async: true

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

    # restored history is seeded synchronously in mount
    transcript = sync(pid).transcript

    assert {:user, "remember the codeword BANANA"} in transcript
    assert {:assistant, "Codeword noted."} in transcript

    tool_line = Enum.find(transcript, fn e -> elem(e, 0) == :tool end)
    assert tool_line != nil and elem(tool_line, 2) =~ "shell"

    # the framework system prompt stays hidden
    refute Enum.any?(transcript, fn e -> text_of_entry(e) =~ "framework prompt" end)
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

    transcript = sync(pid).transcript
    assert Enum.any?(transcript, fn {role, t} -> role == :info and t =~ "compacted" end)
    assert {:assistant, "after compaction"} in transcript
  end

  defp text_of_entry(e) when is_tuple(e) do
    case elem(e, 0) do
      :tool -> elem(e, 3)
      _ -> elem(e, 1)
    end
  end

  describe "tool entries on resume (5c regression)" do
    # Found live: resumed tool messages became {:tool, "▸ name: text"}
    # 2-tuples, which normalize_entry downgraded to :info — full content,
    # always visible, un-toggleable (the 'vertical space as if visible'
    # report). Fixed: proper 4-tuple tool entries.

    test "resumed tool messages are id-ed, collapsible tool entries" do
      sid = "resume-tool-#{System.unique_integer()}"

      context =
        ReqLLM.Context.new()
        |> ReqLLM.Context.append(ReqLLM.Context.system("framework"))
        |> ReqLLM.Context.append(ReqLLM.Context.user("run something"))
        |> ReqLLM.Context.append(
          ReqLLM.Context.tool_result_message(
            "shell",
            "c1",
            "exit 0\n--- output ---\nlineA\nlineB"
          )
        )

      :ok =
        Store.save(
          CodingAgent.Core.Session.State.new(id: sid, context: context, model: "m", status: :idle)
        )

      pid =
        start_supervised!(
          {Tui, [name: nil, test_mode: {80, 24}, resume_id: sid, scope_root: File.cwd!()]}
        )

      st = sync(pid)
      tool = Enum.find(st.transcript, fn e -> elem(e, 0) == :tool end)
      assert tool != nil
      assert elem(tool, 2) == "shell"
      # collapsed by default; ctrl-t opens the most recent tool block
      # (single-open accordion)
      assert st.open_tool_id == nil

      key(pid, "t", ["ctrl"])

      st2 = sync(pid)
      assert st2.open_tool_id == elem(tool, 1)

      key(pid, "t", ["ctrl"])

      assert sync(pid).open_tool_id == nil
    end
  end
end
