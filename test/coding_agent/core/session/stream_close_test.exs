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
end
