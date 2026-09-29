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

  test "resumed sessions carry the persisted usage (no first-command compaction)" do
    # Found live: every resumed session compacted on its first command.
    # The TUI resume path did not forward the snapshot's usage, so the
    # live session defaulted last_input_tokens to 0 and took the chars
    # fallback regardless of the real context size.
    sid = "resume-usage-#{System.unique_integer()}"

    fat =
      for _i <- 1..90 do
        %ReqLLM.Message{
          role: :assistant,
          content: [ReqLLM.Message.ContentPart.text(String.pad_leading("m", 1000, "x"))]
        }
      end

    context = %ReqLLM.Context{
      messages: [
        %ReqLLM.Message{role: :system, content: [ReqLLM.Message.ContentPart.text("sys")]}
        | fat
      ]
    }

    usage = %{input_tokens: 123_456, output_tokens: 7, last_input_tokens: 50_000, cost: nil}

    :ok =
      Store.save(
        CodingAgent.Core.Session.State.new(
          id: sid,
          context: context,
          model: "ollama:test-model",
          status: :idle,
          usage: usage
        )
      )

    pid =
      start_supervised!(
        {Tui, [name: nil, test_mode: {80, 24}, resume_id: sid, scope_root: File.cwd!()]}
      )

    canonical = CodingAgent.Core.Session.Usage.from_map(usage)

    st = sync(pid)
    assert st.session_usage == canonical

    {:ok, live} = CodingAgent.Core.Session.state(sid)
    assert live.usage == canonical
    # >80K chars (chars fallback would fire) but 50k tokens, and the
    # projected size is far below the limits for the fallback window:
    # the decision must be :none
    assert CodingAgent.Core.Session.Compactor.decide(
             live,
             CodingAgent.Core.Session.Compactor.soft_limit(live)
           ) == :none
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

  describe "orderly fallback on an unloadable resume" do
    # User request: a corrupt/invalid session file should produce a
    # friendly message and an orderly retreat — not a crash and not a
    # silent fresh start.

    test "a corrupt session file reports why and starts a fresh session" do
      sid = "resume-corrupt-#{System.unique_integer()}"
      # write a corrupt BLOB straight into the store (the test seam)
      :ok = Store.debug_put(sid, <<1, 2, 3, "not a term">>, encode: false)

      pid =
        start_supervised!(
          {Tui, [name: nil, test_mode: {80, 24}, resume_id: sid, scope_root: File.cwd!()]}
        )

      st = sync(pid)
      # a friendly info line names the id and the reason
      info = Enum.find(st.transcript, fn {role, _} -> role == :info end)
      assert info != nil
      assert elem(info, 1) =~ "could not resume #{sid}"
      assert elem(info, 1) =~ "fresh session"
      # and the session is usable (fresh, not the broken id's state)
      assert st.session_id != sid
      assert st.status == :idle
    end

    test "an unknown session id reports no such session and starts fresh" do
      pid =
        start_supervised!(
          {Tui,
           [
             name: nil,
             test_mode: {80, 24},
             resume_id: "definitely-missing-#{System.unique_integer()}",
             scope_root: File.cwd!()
           ]}
        )

      st = sync(pid)
      info = Enum.find(st.transcript, fn {role, _} -> role == :info end)
      assert info != nil
      assert elem(info, 1) =~ "no such session"
      assert st.status == :idle
    end
  end
end
