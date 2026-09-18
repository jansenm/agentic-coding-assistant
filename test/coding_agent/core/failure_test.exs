defmodule CodingAgent.Core.FailureTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Failure

  defp reason_struct(reason), do: %ReqLLM.Error.API.Stream{reason: reason}

  test "a local request-build failure is not blamed on the provider" do
    err = reason_struct("Failed to build streaming request: invalid byte 0x83 in <<36, 32, 99>>")

    assert {:local, hint} = Failure.classify({:stream_error, err})
    assert hint =~ "local"
    refute hint =~ "check the provider"
  end

  test "connection refused is a provider failure" do
    err =
      reason_struct(
        "Stream failed: %Finch.TransportError{reason: :econnrefused, source: %Mint.TransportError{reason: :econnrefused}}"
      )

    assert {:provider, _} = Failure.classify({:stream_error, err})
  end

  test "auth and quota statuses are provider failures" do
    assert {:provider, _} = Failure.classify(reason_struct("401 Unauthorized"))
    assert {:provider, _} = Failure.classify(reason_struct("429 Too Many Requests"))
  end

  test "a transport timeout is a provider failure" do
    assert {:provider, _} = Failure.classify(reason_struct("request timed out"))
  end

  test "the provider_build_failed wrapper is unwrapped and classified" do
    err = %ReqLLM.Error.API.Request{
      reason: "Failed to build streaming request: invalid byte 0x83"
    }

    assert {:local, _} = Failure.classify({:provider_build_failed, err})
  end

  test "a tool-loop limit is its own bucket, not the provider" do
    assert {:other, hint} = Failure.classify({:tool_loop_limit, 100})
    assert hint =~ "budget"
  end

  test "an unrecognised failure keeps the reason and makes no claim" do
    assert {:other, _} = Failure.classify("something odd happened")
    assert {:other, _} = Failure.classify(:weird_atom)
    assert {:other, _} = Failure.classify(nil)
  end

  describe "provider_reason/1 (probe classification)" do
    test "names auth and quota statuses" do
      assert Failure.provider_reason(%{status: 401}) =~ "credentials (401)"
      assert Failure.provider_reason(%{status: 403}) =~ "credentials (403)"
      assert Failure.provider_reason(%{status: 429}) =~ "quota exceeded (429)"
    end

    test "humanizes transport causes" do
      assert Failure.provider_reason(%{reason: "econnrefused"}) =~ "connection refused"
      assert Failure.provider_reason(%{reason: "request timed out"}) =~ "did not answer in time"
      assert Failure.provider_reason(%{reason: "nxdomain"}) =~ "host not found"
    end

    test "anything else keeps the raw reason, never a generic unknown" do
      assert Failure.provider_reason(%{reason: "weird%with%percent"}) == "weird"
      assert Failure.provider_reason(:odd) =~ "provider error"
    end
  end
end
