defmodule CodingAgent.Core.CostsTest do
  @moduledoc """
  The billing probe: derived from the provider HOST, never from config,
  and never from a local price table. These tests inject both the
  transport and the key, so they are network-free and independent of the
  machine's `auth.toml`.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Costs

  @ollama %{
    "ollama_cloud" => %{
      "provider" => "openai",
      "base_url" => "https://ollama.com/v1",
      "backend" => "ollama",
      "discover" => "openai"
    }
  }

  @local %{
    "ollama" => %{"base_url" => "http://localhost:11434"}
  }

  @usage %{
    "totals" => %{
      "usage_usd" => 11.71848,
      "input_tokens" => 128_179_185,
      "cached_input_tokens" => 56_873_460,
      "output_tokens" => 1_411_059,
      "request_count" => 1_084
    }
  }

  @balance %{
    "included" => %{
      "allowance_usd" => 60,
      "balance_usd" => 7.21675,
      "period" => %{"from" => "2026-10-11T19:13:03Z", "until" => "2026-11-11T19:13:03Z"}
    },
    "purchased" => %{"balance_usd" => 0}
  }

  # A transport that answers with `status`/`body`; when a pid is given it
  # also reports what was asked for, so the URL and the key are pinned.
  defp get_returning(status, body, sent \\ nil) do
    fn url, key ->
      if is_pid(sent), do: send(sent, {:fetched, url, key})
      {:ok, status, body}
    end
  end

  describe "target/2 (derived from the host, not declared)" do
    test "the ollama cloud host, with the /v1 chat path stripped" do
      assert Costs.target("ollama_cloud:deepseek-v4.1-flash", @ollama) ==
               {:ok, :ollama, "https://ollama.com"}
    end

    test "a local daemon has no billing API — a local model costs nothing" do
      assert Costs.target("ollama:qwen", @local) == :none
    end

    test "a native provider with no base_url, and an unknown provider, have none" do
      assert Costs.target("openai:gpt-4o", %{}) == :none
      assert Costs.target("nope:model", %{}) == :none
      assert Costs.target(nil, @ollama) == :none
    end

    test "an unknown host is not probed (no speculative requests)" do
      cfg = %{"x" => %{"provider" => "openai", "base_url" => "https://api.example.com/v1"}}
      assert Costs.target("x:model", cfg) == :none
    end
  end

  describe "snapshot/3" do
    test "reads the account totals the provider reports" do
      assert {:ok, snap} =
               Costs.snapshot("ollama_cloud:m", @ollama,
                 credential: {:ok, %{api_key: "k"}},
                 get: get_returning(200, @usage)
               )

      assert %{
               usd: 11.71848,
               input: 128_179_185,
               cached: 56_873_460,
               output: 1_411_059,
               requests: 1_084
             } = snap

      # the wall clock rides along, so a caller can tell a fresh sample from
      # a stale one without asking the provider again
      assert is_integer(snap.at)
    end

    test "asks the billing origin, not the chat path, with the session's key" do
      test_pid = self()

      Costs.snapshot("ollama_cloud:m", @ollama,
        credential: {:ok, %{api_key: "secret"}},
        get: get_returning(200, @usage, test_pid)
      )

      assert_received {:fetched, url, key}
      assert url == "https://ollama.com/api/usage?range=24h"
      assert key == "secret"
    end

    test "has a baseline before a number: no probe means :none" do
      assert Costs.snapshot("ollama:qwen", @local,
               credential: {:ok, %{api_key: "k"}},
               get: get_returning(200, @usage)
             ) ==
               :none
    end

    test "an HTTP failure or an unexpected body yields an error, never a number" do
      assert {:error, {:http, 500}} =
               Costs.snapshot("ollama_cloud:m", @ollama,
                 credential: {:ok, %{api_key: "k"}},
                 get: get_returning(500, %{})
               )

      assert {:error, :unexpected_body} =
               Costs.snapshot("ollama_cloud:m", @ollama,
                 credential: {:ok, %{api_key: "k"}},
                 get: get_returning(200, %{})
               )
    end

    test "no credential means no request at all" do
      test_pid = self()

      assert {:error, :none} =
               Costs.snapshot("ollama_cloud:m", @ollama,
                 credential: {:error, :none},
                 get: get_returning(200, @usage, test_pid)
               )

      refute_received {:fetched, _, _}
    end
  end

  describe "balance/3" do
    test "reads remaining credits and the period" do
      assert {:ok, b} =
               Costs.balance("ollama_cloud:m", @ollama,
                 credential: {:ok, %{api_key: "k"}},
                 get: get_returning(200, @balance)
               )

      assert b.remaining == 7.21675
      assert b.allowance == 60.0
      assert b.purchased == 0.0
      assert b.from == "2026-10-11T19:13:03Z"
      assert b.until == "2026-11-11T19:13:03Z"
    end

    test "a legacy percent plan yields no dollar figure" do
      legacy = %{
        "included" => %{
          "session" => %{"remaining_percent" => 75, "resets_at" => "2026-10-01T07:00:00Z"},
          "weekly" => %{"remaining_percent" => 40, "resets_at" => "2026-10-05T00:00:00Z"}
        },
        "purchased" => %{"balance_usd" => 25}
      }

      assert Costs.balance("ollama_cloud:m", @ollama,
               credential: {:ok, %{api_key: "k"}},
               get: get_returning(200, legacy)
             ) ==
               :none
    end

    test "a rate limit is an error the caller can ignore without dropping the last value" do
      assert {:error, :rate_limited} =
               Costs.balance("ollama_cloud:m", @ollama,
                 credential: {:ok, %{api_key: "k"}},
                 get: get_returning(429, %{})
               )
    end
  end
end
