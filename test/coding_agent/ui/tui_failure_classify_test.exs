defmodule CodingAgent.UI.TuiFailureClassifyTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Tui

  defp reason_struct(reason), do: %ReqLLM.Error.API.Stream{reason: reason}

  test "a local request-build failure is not blamed on the provider" do
    # the exact shape that sent a real session chasing ollama: an invalid
    # UTF-8 byte in the context made the request unencodable
    err = reason_struct("Failed to build streaming request: invalid byte 0x83 in <<36, 32, 99>>")

    assert {:local, hint} = Tui.classify_failure({:stream_error, err})
    assert hint =~ "local"
    refute hint =~ "check the provider"
  end

  test "connection refused is a provider failure" do
    err =
      reason_struct(
        "Stream failed: %Finch.TransportError{reason: :econnrefused, source: %Mint.TransportError{reason: :econnrefused}}"
      )

    assert {:provider, _} = Tui.classify_failure({:stream_error, err})
  end

  test "auth and quota statuses are provider failures" do
    assert {:provider, _} = Tui.classify_failure(reason_struct("401 Unauthorized"))
    assert {:provider, _} = Tui.classify_failure(reason_struct("429 Too Many Requests"))
  end

  test "a transport timeout is a provider failure" do
    assert {:provider, _} = Tui.classify_failure(reason_struct("request timed out"))
  end

  test "the provider_build_failed wrapper is unwrapped and classified" do
    err = %ReqLLM.Error.API.Request{
      reason: "Failed to build streaming request: invalid byte 0x83"
    }

    assert {:local, _} = Tui.classify_failure({:provider_build_failed, err})
  end

  test "a tool-loop limit is its own bucket, not the provider" do
    assert {:other, hint} = Tui.classify_failure({:tool_loop_limit, 100})
    assert hint =~ "budget"
  end

  test "an unrecognised failure keeps the reason and makes no claim" do
    assert {:other, _} = Tui.classify_failure("something odd happened")
    assert {:other, _} = Tui.classify_failure(:weird_atom)
    assert {:other, _} = Tui.classify_failure(nil)
  end
end
