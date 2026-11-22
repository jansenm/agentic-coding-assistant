# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.TuiSwitchFailureTest do
  # async: false — the test switches the process-global sandbox env (see
  # CodingAgent.SandboxCase), which no concurrent session may observe.
  use CodingAgent.TuiCase, async: false

  import CodingAgent.SandboxCase

  alias CodingAgent.Core.Events
  alias CodingAgent.Core.Session
  alias CodingAgent.TestSandbox.Unavailable
  alias CodingAgent.UI.Tui

  @tmp_root System.tmp_dir!() |> Path.join("tui-switch-#{System.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  # A persisted session for the switch popup to select. The initial mount
  # is a fresh, unpersisted session, so this is the only row at risk of
  # being confused with it.
  defp seed_session do
    id = "switch-#{System.unique_integer([:positive])}"

    ctx = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))

    state =
      Session.State.new(
        id: id,
        context: ctx,
        model: "m",
        status: :idle,
        scope_root: @tmp_root,
        policy: CodingAgent.Core.Permissions.load(nil, nil)
      )

    Session.Store.save(state)
    id
  end

  defp subscribed?(id, pid) do
    Registry.lookup(CodingAgent.EventRegistry, {Events.key(), id})
    |> Enum.any?(fn {registered, _} -> registered == pid end)
  end

  test "a switch that fails to mount leaves the displayed session subscribed" do
    target = seed_session()

    pid = start_supervised!({Tui, [name: nil, test_mode: {100, 30}, scope_root: @tmp_root]})
    original = sync(pid).session_id

    assert subscribed?(original, pid), "the initial mount did not subscribe its session"

    # Open the switch list and select the persisted session.
    key(pid, "x", ["ctrl"])
    key(pid, "s")

    popup = sync(pid).menu_popup
    assert popup.id == :switch_session
    index = Enum.find_index(popup.items, &(&1.id == target))
    assert index, "the seeded session is not in the switch list"

    Enum.each(1..index//1, fn _ -> key(pid, "down") end)

    # Make the target's start fail the way a host without a usable sandbox
    # fails (ADR 030): `Session.resume/2` returns `{:error, _}` and the TUI
    # keeps the old state on screen. Before the fix it had already
    # unsubscribed that old session, so it went deaf.
    put_sandbox(Unavailable)
    key(pid, "enter")

    state = sync(pid)
    assert state.session_id == original
    assert state.menu_note =~ "switch failed"

    assert subscribed?(original, pid),
           "the failed switch unsubscribed the session still on screen"
  end
end
