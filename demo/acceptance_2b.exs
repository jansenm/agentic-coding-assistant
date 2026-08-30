# Slice 2b acceptance demo (deterministic core, no LLM round-trip):
# The SAME write_file call takes two different paths, driven ONLY by
# editing agent-permissions.toml — the ADR 010 acceptance criterion.

demo_dir = "/tmp/opencode/demo-2b"
policy_file = Path.join(demo_dir, "agent-permissions.toml")

File.rm_rf!(demo_dir)
File.mkdir_p!(Path.join(demo_dir, "docs"))

File.write!(policy_file, """
[tools]
enabled = ["list_dir", "read_file", "write_file"]

[permissions.write_file]
"docs/**" = "allow"
""")

alias CodingAgent.Core.{Permissions, Session}

{:ok, _} =
  CodingAgent.Core.Session.Supervisor.start_session(
    id: "demo-2b",
    scope_root: demo_dir,
    policy: Permissions.load(nil, policy_file),
    test_mode: true
  )


call = fn id ->
  Session.debug_gate(id, [
    %{id: "c1", name: "write_file", arguments: %{"path" => "docs/demo.md", "content" => "demo"}}
  ])

  Session.state(id)
end

IO.puts("== phase A: docs/** = allow ==")
# In test_mode the gate skips the LLM continue; allow executes the tool.
{:ok, _} = call.("demo-2b")
IO.puts("file written?  #{File.exists?(Path.join(demo_dir, "docs/demo.md"))}")

File.rm!(Path.join(demo_dir, "docs/demo.md"))

# Reload policy — sessions load policy at START (ADR 010), so restart:
File.write!(policy_file, """
[tools]
enabled = ["list_dir", "read_file", "write_file"]

[permissions.write_file]
"docs/**" = "ask"
""")

{:ok, _} =
  CodingAgent.Core.Session.Supervisor.start_session(
    id: "demo-2b-b",
    scope_root: demo_dir,
    policy: Permissions.load(nil, policy_file),
    test_mode: true
  )

IO.puts("\n== phase B: docs/** = ask (edited policy file) ==")
{:ok, state_b} = call.("demo-2b-b")
IO.puts("session status: #{state_b.status}  (expected: interrupted)")
IO.puts("pending calls:  #{length(state_b.pending_tool_calls)}")
IO.puts("file written?   #{File.exists?(Path.join(demo_dir, "docs/demo.md"))} (expected: false)")

IO.puts("\n== phase C: human approves ==")
{:ok, state_c} = Session.decide("demo-2b-b", [%{id: "c1", decision: :approve}])
IO.puts("session status: #{state_c.status}")
IO.puts("file written?   #{File.exists?(Path.join(demo_dir, "docs/demo.md"))}")
IO.puts("content:        #{File.read!(Path.join(demo_dir, "docs/demo.md")) |> String.trim()}")

File.rm!(Path.join(demo_dir, "docs/demo.md"))

# Same interruption again, this time reject:
IO.puts("\n== phase D: human rejects ==")
:ok = Session.debug_gate("demo-2b-b", [
  %{id: "c2", name: "write_file", arguments: %{"path" => "docs/demo.md", "content" => "should not exist"}}
])

{:ok, _} = Session.decide("demo-2b-b", [%{id: "c2", decision: :reject}])
IO.puts("file written?   #{File.exists?(Path.join(demo_dir, "docs/demo.md"))} (expected: false)")

IO.puts("\n== acceptance: PASS (same call, two outcomes, only the file changed) ==")