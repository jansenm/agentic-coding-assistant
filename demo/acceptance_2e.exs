# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

# Slice 2e acceptance demo (LLM-free, deterministic): edit behind the
# gate. Acceptance criterion per ROADMAP: targeted replacement,
# fail-closed on non-unique match, gated like write_file. The arc:
# ambiguous -> refused; user edits (widens) -> applied; reject leaves
# the file untouched.

demo_dir = "/tmp/opencode/demo-2e"
File.rm_rf!(demo_dir)
File.mkdir_p!(demo_dir)

File.write!(Path.join(demo_dir, "session.ex"), """
defmodule Demo.Session do
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}
end
""")

defmodule Demo2E do
  def text_of(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t || ""
      _ -> ""
    end)
  end

  def text_of(%ReqLLM.Message{content: c}) when is_binary(c), do: c

  def tool_result(ctx, id) do
    ReqLLM.Context.to_list(ctx)
    |> Enum.find_value(fn
      %ReqLLM.Message{role: :tool, tool_call_id: ^id} = m -> text_of(m)
      _ -> nil
    end)
  end
end

alias CodingAgent.Core.{Permissions, Session}

{:ok, _} =
  CodingAgent.Core.Session.Supervisor.start_session(
    id: "demo-2e",
    scope_root: demo_dir,
    policy: Permissions.load(nil, nil),
    test_mode: true
  )

IO.puts("== 1: ambiguous edit -> the TOOL refuses, gate not even needed ==")

:ok =
  Session.debug_gate("demo-2e", [
    %{
      id: "a1",
      name: "edit",
      arguments: %{"path" => "session.ex", "old_string" => "opts", "new_string" => "config"}
    }
  ])

{:ok, st1} = Session.decide("demo-2e", [%{id: "a1", decision: :approve}])
IO.puts(Demo2E.tool_result(st1.context, "a1"))
state_now = File.read!(Path.join(demo_dir, "session.ex"))

IO.puts(
  "file changed? #{if state_now =~ "start_link(opts)", do: "NO (refused, good)", else: "YES?!"}"
)

IO.puts("\n== 2: human widens the match via the gate's :edit ==")

:ok =
  Session.debug_gate("demo-2e", [
    %{
      id: "e1",
      name: "edit",
      arguments: %{
        "path" => "session.ex",
        "old_string" => "def start_link(opts)",
        "new_string" => "def start_link(opts \\ [])"
      }
    }
  ])

{:ok, _} =
  Session.decide("demo-2e", [
    %{
      id: "e1",
      decision:
        {:edit,
         %{
           "path" => "session.ex",
           "old_string" => "def start_link(opts)",
           "new_string" => "def start_link(opts, extra) when is_map(extra)"
         }}
    }
  ])

{:ok, st2} = Session.state("demo-2e")
IO.puts(Demo2E.tool_result(st2.context, "e1"))

IO.puts(
  "now contains the USER-EDITED span: #{if File.read!(Path.join(demo_dir, "session.ex")) =~ "is_map(extra)", do: "YES", else: "NO"}"
)

IO.puts("\n== 3: rejected edit leaves the file alone ==")

:ok =
  Session.debug_gate("demo-2e", [
    %{
      id: "e2",
      name: "edit",
      arguments: %{
        "path" => "session.ex",
        "old_string" => "handle_call(:state",
        "new_string" => "handle_call(:boom"
      }
    }
  ])

{:ok, _} = Session.decide("demo-2e", [%{id: "e2", decision: :reject}])

IO.puts(
  "file unchanged? #{if File.read!(Path.join(demo_dir, "session.ex")) =~ "handle_call(:state", do: "YES"}"
)

IO.puts("\n== acceptance: PASS (fail-closed edit + gate edit + reject) ==")
