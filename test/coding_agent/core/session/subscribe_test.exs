# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.SubscribeTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Events
  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session

  @tmp_root System.tmp_dir!()
            |> Path.join("agent-subscribe-#{System.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  defp start_session do
    id = "subscribe-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: id,
        scope_root: @tmp_root,
        policy: Permissions.load(nil, nil),
        test_mode: true
      )

    id
  end

  test "a live session registers the caller and returns :ok" do
    id = start_session()

    assert :ok = Session.subscribe(id)
    assert [{pid, _}] = Registry.lookup(CodingAgent.EventRegistry, {Events.key(), id})
    assert pid == self()
  end

  # The TUI calls this right after starting a session; the session runs
  # `restart: :temporary`, so it can die in between. `subscribe/1` used to
  # be the one public action without `safe_call/4` and took the caller (the
  # TUI server) down with the `:exit` (review N128).
  test "a dead session returns an error instead of exiting, and leaves no registry entry" do
    id = start_session()
    :ok = Session.stop(id)

    assert {:error, :not_found} = Session.subscribe(id)
    assert [] = Registry.lookup(CodingAgent.EventRegistry, {Events.key(), id})
  end
end
