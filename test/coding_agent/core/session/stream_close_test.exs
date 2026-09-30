defmodule CodingAgent.Core.Session.StreamCloseTest do
  @moduledoc """
  Regression for review N29: when a provider stream fails mid-flight, the
  session retries the turn, but `req_llm`'s transport retry loop
  (`ReqLLM.Streaming.Retry.stream/6`, which classifies a pre-body timeout
  as `{:retry, 0}`) may still be reconnecting BEHIND the surfaced error.
  Abandoning the stream without closing it leaves those attempts running:
  one failed turn can hit the provider many times (measured 11 sockets
  with the bug, 4 with the close). `stream_attempt/2` now closes the
  response in its error path.

  The stub is a silent local server that accepts a connection and never
  answers, so the client hits `receive_timeout`; the test counts sockets.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session

  defp start_stub do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    counter = :counters.new(1, [])
    spawn_link(fn -> accept_loop(listen, counter) end)
    %{port: port, listen: listen, counter: counter}
  end

  # One handler per connection, held open and silent: the client's
  # receive_timeout fires per attempt, and spawned handlers let parallel
  # retries register as separate sockets.
  defp accept_loop(listen, counter) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        :counters.add(counter, 1, 1)

        spawn(fn ->
          receive do
            :release -> :gen_tcp.close(sock)
          after
            60_000 -> :gen_tcp.close(sock)
          end
        end)

        accept_loop(listen, counter)

      {:error, :closed} ->
        :ok
    end
  end

  defp connections(counter), do: :counters.get(counter, 1)

  test "a failed turn does not leave req_llm transport retries running (N29)" do
    root = Path.join(System.tmp_dir!(), "n29-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".coding-agent"))
    on_exit(fn -> File.rm_rf!(root) end)

    stub = start_stub()

    File.write!(
      Path.join(root, ".coding-agent/config.toml"),
      "[providers.local]\nprovider = \"openai\"\nbase_url = \"http://127.0.0.1:#{stub.port}/v1\"\n"
    )

    Application.put_env(:coding_agent, :provider_receive_timeout_ms, 400)
    Application.put_env(:coding_agent, :provider_retries, 3)
    Application.put_env(:coding_agent, :provider_retry_delay_ms, 100)

    on_exit(fn ->
      Enum.each(
        [:provider_receive_timeout_ms, :provider_retries, :provider_retry_delay_ms],
        &Application.delete_env(:coding_agent, &1)
      )
    end)

    id = "n29-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: id,
        scope_root: root,
        model: "local:test-model"
      )

    assert {:error, _} = Session.run(id, "hi")

    # Settle: any abandoned transport retry would open more sockets here.
    Process.sleep(2_000)
    settled = connections(stub.counter)

    # The session makes at most `provider_retries + 1` attempts, so with
    # the stream closed that bounds the sockets. Without the close, each
    # attempt's own req_llm retry chain multiplies this (measured 11).
    assert settled <= 4

    Session.stop(id)
  end

  # A stub that sends SSE headers and one data chunk, then goes silent:
  # the timeout must fire on the IDLE gap, not only at connect (ADR 041
  # finding 2, review N28). Fast (the timeout is 400ms), unlike a 30s
  # premise test.
  defp start_stalling_stub do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen)
      # headers + an open SSE event, then silence (no terminating blank line)
      :gen_tcp.send(sock, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n")
      :gen_tcp.send(sock, "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")

      receive do
        :release -> :gen_tcp.close(sock)
      after
        30_000 -> :gen_tcp.close(sock)
      end
    end)

    %{port: port, listen: listen}
  end

  test "the timeout bounds a post-header idle gap, not just connect (N28)" do
    root = Path.join(System.tmp_dir!(), "n28-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".coding-agent"))
    on_exit(fn -> File.rm_rf!(root) end)

    stub = start_stalling_stub()

    File.write!(
      Path.join(root, ".coding-agent/config.toml"),
      "[providers.local]\nprovider = \"openai\"\nbase_url = \"http://127.0.0.1:#{stub.port}/v1\"\n"
    )

    Application.put_env(:coding_agent, :provider_receive_timeout_ms, 400)
    Application.put_env(:coding_agent, :provider_retries, 0)

    on_exit(fn ->
      Enum.each(
        [:provider_receive_timeout_ms, :provider_retries],
        &Application.delete_env(:coding_agent, &1)
      )
    end)

    id = "n28-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      CodingAgent.Core.Session.Supervisor.start_session(
        id: id,
        scope_root: root,
        model: "local:test-model"
      )

    started = System.monotonic_time(:millisecond)
    # the stream stalls after the first chunk: the turn fails on the idle
    # budget, well before the stub's own 30s close
    assert {:error, _} = Session.run(id, "hi")
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 5_000

    Session.stop(id)
    :gen_tcp.close(stub.listen)
  end
end
