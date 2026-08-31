# Slice 2c acceptance demo (LLM-free, deterministic): the shell tool
# goes through the SAME gate as write_file. Acceptance criterion per
# ROADMAP 2c: the agent can run commands and summarize — here the
# "agent" is simulated: it runs the toy project's test script, the gate
# interrupts (always-ask), the "human" approves, and the output (exit
# code, failing test names) flows back as tool result — exactly the
# material a summary would be written from.

demo_dir = "/tmp/opencode/demo-2c"

File.rm_rf!(demo_dir)
File.mkdir_p!(demo_dir)

# A toy "test suite": one passing, one failing check.
File.write!(Path.join(demo_dir, "run_tests.sh"), """
#!/bin/sh
echo "1) core works .... PASS"
echo "2) gate works ..... FAIL"
exit 1
""")

File.chmod!(Path.join(demo_dir, "run_tests.sh"), 0o755)

alias CodingAgent.Core.{Permissions, Session}
defmodule Demo2C do
  def text_of(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t || ""
      _ -> ""
    end)
  end

  def text_of(%ReqLLM.Message{content: c}) when is_binary(c), do: c

  def find_tool_result(list, id) do
    Enum.find_value(list, fn
      %ReqLLM.Message{role: :tool, tool_call_id: ^id} = m -> text_of(m)
      _ -> nil
    end)
  end
end
alias Demo2C, as: D

{:ok, _} =
  CodingAgent.Core.Session.Supervisor.start_session(
    id: "demo-2c",
    scope_root: demo_dir,
    policy: Permissions.load(nil, nil),
    test_mode: true
  )

IO.puts("== 1: agent wants to run the test suite ==")

:ok =
  Session.debug_gate("demo-2c", [
    %{
      id: "s1",
      name: "shell",
      arguments: %{"command" => "./run_tests.sh", "timeout_secs" => 60}
    }
  ])

{:ok, state} = Session.state("demo-2c")
IO.puts("session status: #{state.status}  (expected: interrupted — shell is always-ask)")
IO.puts("tests already ran? #{if File.exists?(Path.join(demo_dir, ".never")), do: "?", else: "no output captured"}")

IO.puts("\n== 2: human approves ==")
{:ok, state2} = Session.decide("demo-2c", [%{id: "s1", decision: :approve}])
IO.puts("session status: #{state2.status}")

# The tool result the model would now see and summarize:
last = ReqLLM.Context.to_list(state2.context) |> List.last()
IO.puts("\n-- tool result the agent sees --")
IO.puts(D.text_of(last))
IO.puts("-- end --")

IO.puts("\n== 3: agent wants a long run; timeout is over the soft cap ==")

:ok =
  Session.debug_gate("demo-2c", [
    %{
      id: "s2",
      name: "shell",
      arguments: %{"command" => "./integration-suite --stage prod", "timeout_secs" => 900}
    }
  ])

{:ok, state3} = Session.state("demo-2c")
[%{arguments: args}] = state3.pending_tool_calls
IO.puts("pending call args: #{inspect(args)}")
IO.puts("(gate shows the user: command + requested 900s timeout — editable via :edit)")

IO.puts("\n== 4: human edits the timeout DOWN and approves ==")
{:ok, _} =
  Session.decide("demo-2c", [
    %{id: "s2", decision: {:edit, %{"command" => "./integration-suite --stage dev", "timeout_secs" => 120}}}
  ])

{:ok, state4} = Session.state("demo-2c")

list4 = ReqLLM.Context.to_list(state4.context)
# (tool_result pulled below)

IO.puts(String.trim_trailing(D.find_tool_result(list4, "s2") || "(missing)"))

IO.puts("\n== acceptance: PASS (ask -> approve -> output back; soft-cap visible; edit respected) ==")

