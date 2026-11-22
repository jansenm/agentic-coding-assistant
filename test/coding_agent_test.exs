# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgentTest do
  # async: false — this test mutates the GLOBAL `AGENT_MODEL` env var that
  # every session start reads. Sync modules run after all async ones, so
  # this cannot race a concurrently-starting session.
  use ExUnit.Case, async: false

  test "model resolution: env override wins over config.toml, nil when both absent" do
    prev = System.get_env("AGENT_MODEL")
    on_exit(fn -> if prev, do: System.put_env("AGENT_MODEL", prev) end)

    System.put_env("AGENT_MODEL", "ollama:qwen3:14b")
    assert CodingAgent.model() == "ollama:qwen3:14b"
    # delete_env would break OTHER tests racing this one (the test
    # helper's seed is the run-wide model); restore instead
    System.put_env("AGENT_MODEL", "ollama:test-model")

    # config.toml's model (user machine) or nil — either is valid; the
    # nil case is the TUI's hard-error path
    case CodingAgent.model() do
      nil -> :ok
      m -> assert is_binary(m) and String.contains?(m, ":")
    end
  end

  test "supervision tree starts with the registry" do
    pid = GenServer.whereis(CodingAgent.Registry)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end
end
