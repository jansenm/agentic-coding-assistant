# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

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

    %{port: port, pid: pid, listen: listen}
  end

  defp accept(listen, body, parent) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        {:ok, req} = :gen_tcp.recv(sock, 0, 2_000)
        send(parent, {:req, req})

        resp =
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

        :gen_tcp.send(sock, resp)
        :gen_tcp.close(sock)
        accept(listen, body, parent)

      # stop_stub closed the listen socket: exit quietly (a crash here
      # would print a process error over the test output)
      {:error, :closed} ->
        :ok
    end
  end

  # Close the LISTEN socket too, not just the acceptor: a killed
  # acceptor leaves the port listening with no one to answer, so the
  # next request hangs until the 3 s receive_timeout (found: the cache
  # test's post-invalidate fetch waited out the full timeout). Closing
  # the listen socket gives the next connect an immediate econnrefused.
  defp stop_stub(%{pid: pid, listen: listen}) do
    :gen_tcp.close(listen)
    Process.exit(pid, :kill)
  end

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

  describe "catalog half (review N5)" do
    # The catalog keys providers by ATOM; comparing the string never
    # matched, so this half of the menu was always empty. Requires a warm
    # catalog (the app warms it) and a resolvable credential for the scope.
    test "a native catalog provider yields entries once the catalog is ready and a key exists" do
      wait_catalog()
      System.put_env("OPENAI_API_KEY", "test-key")
      on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

      assert {:ok, %{entries: entries, note: nil}} = Discovery.models("openai", %{})
      assert entries != []
      assert Enum.all?(entries, &(&1.source == :catalog))
      # the ids are bare model ids, NOT "openai:model" (the menu re-prefixes)
      assert Enum.any?(entries, &(&1.id == "gpt-4o"))
      refute Enum.any?(entries, &String.starts_with?(&1.id, "openai:"))
    end

    defp wait_catalog(deadline \\ System.monotonic_time(:millisecond) + 10_000) do
      cond do
        CodingAgent.Core.Providers.Catalog.ready?() -> :ok
        System.monotonic_time(:millisecond) >= deadline -> flunk("catalog never ready")
        true -> Process.sleep(20) && wait_catalog(deadline)
      end
    end
  end

  describe "all_models_cached/1" do
    test "second call is served from the process cache" do
      wait_catalog()
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

      assert {:ok, %{entries: entries}} = Discovery.all_models_cached(cfg)
      assert Enum.any?(entries, &(&1.id == "loc:one"))
      # kill the server: the cached path must not refetch
      stop_stub(stub)
      assert {:ok, %{entries: entries2}} = Discovery.all_models_cached(cfg)
      assert Enum.any?(entries2, &(&1.id == "loc:one"))

      Discovery.invalidate()
      assert {:ok, %{entries: post}} = Discovery.all_models_cached(cfg)
      refute Enum.any?(post, &(&1.id == "loc:one"))
    end

    test "does not cache while the catalog is still loading (review N24)" do
      # A cold menu open returned `{[], nil}` (the `Catalog.ready?/0` guard
      # in catalog_models/1) and cached it, pinning the empty catalog half
      # for the process lifetime. This owns the global llm_db store for its
      # duration and reloads on exit so later sync tests still see a catalog.
      LLMDB.Catalog.clear!()
      on_exit(fn -> LLMDB.load() end)
      refute CodingAgent.Core.Providers.Catalog.ready?()

      # a FRESH process: the cache lives in the process dictionary
      cached? =
        Task.async(fn ->
          {:ok, _} = Discovery.all_models_cached(%{})
          Process.get(:__discovery_all_cache__)
        end)
        |> Task.await(5_000)

      assert cached? == nil

      # once ready, the fetch is cached as before
      LLMDB.load()
      assert CodingAgent.Core.Providers.Catalog.ready?()

      cached? =
        Task.async(fn ->
          {:ok, _} = Discovery.all_models_cached(%{})
          Process.get(:__discovery_all_cache__) != nil
        end)
        |> Task.await(5_000)

      assert cached?
    end
  end
end
