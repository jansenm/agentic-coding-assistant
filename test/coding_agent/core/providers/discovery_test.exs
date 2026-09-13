defmodule CodingAgent.Core.Providers.DiscoveryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Providers.Discovery

  # one raw gen_tcp responder per test: replies to the first request
  # with `body`, records the request bytes for assertions
  defp start_stub(body) do
    parent = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    # NOT spawn_link: stop_stub kills this pid mid-test — a link would
    # take the test process down with it (found: "(EXIT) killed")
    pid =
      spawn(fn -> accept(listen, body, parent) end)

    %{port: port, pid: pid}
  end

  defp accept(listen, body, parent) do
    {:ok, sock} = :gen_tcp.accept(listen)
    {:ok, req} = :gen_tcp.recv(sock, 0, 2_000)
    send(parent, {:req, req})

    resp =
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

    :gen_tcp.send(sock, resp)
    :gen_tcp.close(sock)
    accept(listen, body, parent)
  end

  defp stop_stub(%{pid: pid}), do: Process.exit(pid, :kill)

  describe "models/2 (menu-facing, never raises)" do
    test "unknown discover dialect: note, no entries, no raise" do
      cfg = %{
        "providers" => %{
          "myproxy" => %{
            "provider" => "openai",
            "base_url" => "http://127.0.0.1:1/v1",
            "discover" => "rss"
          }
        }
      }

      assert {:ok, %{entries: [], note: note}} = Discovery.models("myproxy", cfg)
      assert note =~ "unknown discover dialect"
    end

    test "no discover field: silent skip (catalog-only path)" do
      cfg = %{"providers" => %{"ollama" => %{"base_url" => "http://127.0.0.1:1"}}}
      assert {:ok, %{entries: [], note: nil}} = Discovery.models("ollama", cfg)
    end

    test "dead endpoint: provider-prefixed note" do
      cfg = %{
        "providers" => %{
          "dead" => %{
            "provider" => "openai",
            "base_url" => "http://127.0.0.1:1/v1",
            "discover" => "openai"
          }
        }
      }

      assert {:ok, %{entries: [], note: note}} = Discovery.models("dead", cfg)
      assert note =~ "dead:"
    end

    test "entry without base_url: note, skip" do
      # a native provider name (ollama is a real req_llm provider) with
      # discover but no base_url
      cfg = %{"providers" => %{"ollama" => %{"discover" => "openai"}}}
      assert {:ok, %{entries: [], note: note}} = Discovery.models("ollama", cfg)
      assert note =~ "no base_url"
    end
  end

  describe "fetch/3 dialects" do
    test "openai: GET <base>/models, ids from data[], non-ids dropped, sorted" do
      stub = start_stub(~s({"data": [{"id": "m2"}, {"id": "m1"}, {"no": "id"}]}))

      assert {:ok, ["m1", "m2"]} =
               Discovery.fetch("openai", "http://127.0.0.1:#{stub.port}/v1", :none)

      assert_received {:req, req}
      assert req =~ "GET /v1/models"
      stop_stub(stub)
    end

    test "ollama: GET <base>/api/tags, names from models[]" do
      stub = start_stub(~s({"models": [{"name": "q3:14b"}, {"name": "glm:5"}]}))

      assert {:ok, ["glm:5", "q3:14b"]} =
               Discovery.fetch("ollama", "http://127.0.0.1:#{stub.port}", :none)

      assert_received {:req, req}
      assert req =~ "GET /api/tags"
      stop_stub(stub)
    end

    test "bearer auth attached when credential resolves" do
      stub = start_stub(~s({"data": []}))

      {:ok, _} =
        Discovery.fetch(
          "openai",
          "http://127.0.0.1:#{stub.port}/v1",
          {:ok, "secret-key"}
        )

      assert_received {:req, req}
      assert req =~ "authorization: Bearer secret-key"
      stop_stub(stub)
    end

    test "HTTP error status: {:error, msg}, no raise" do
      # port 1: nothing listens → connection refused
      assert {:error, _} = Discovery.fetch("openai", "http://127.0.0.1:1/v1", :none)
    end
  end

  describe "models_cached/2" do
    test "second call is served from the process cache" do
      stub = start_stub(~s({"models": [{"name": "one"}]}))

      cfg = %{
        "providers" => %{
          "loc" => %{
            "provider" => "openai",
            "discover" => "ollama",
            "base_url" => "http://127.0.0.1:#{stub.port}"
          }
        }
      }

      assert {:ok, %{entries: [%{id: "one"}]}} = Discovery.models_cached("loc", cfg)
      # kill the server: the cached path must not refetch
      stop_stub(stub)
      assert {:ok, %{entries: [%{id: "one"}]}} = Discovery.models_cached("loc", cfg)

      Discovery.invalidate("loc")
      assert {:ok, %{entries: [], note: note}} = Discovery.models_cached("loc", cfg)
      assert note != nil
    end
  end
end
