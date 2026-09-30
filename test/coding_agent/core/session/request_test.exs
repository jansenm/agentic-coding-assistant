defmodule CodingAgent.Core.Session.RequestTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session.Request

  @provider_cfg %{
    "providers" => %{
      "ollama_cloud" => %{
        "provider" => "openai",
        "base_url" => "https://ollama.com/v1",
        "backend" => "ollama"
      },
      "ollama" => %{"base_url" => "http://localhost:11434/v1"}
    }
  }

  setup do
    prev = System.get_env("OLLAMA_API_KEY")
    on_exit(fn -> restore("OLLAMA_API_KEY", prev) end)
    System.delete_env("OLLAMA_API_KEY")
    :ok
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  test "a native provider passes the spec string through, keyless" do
    assert {:ok, "ollama:qwen3:14b", opts} = Request.build("ollama:qwen3:14b", %{})
    refute Keyword.has_key?(opts, :api_key)
  end

  test "an indirected provider builds a req_llm model map with its base_url" do
    assert {:ok, model_input, opts} = Request.build("ollama_cloud:glm-5.3", @provider_cfg)

    assert %{provider: :openai, id: "glm-5.3", base_url: "https://ollama.com/v1"} = model_input
    assert opts[:base_url] == "https://ollama.com/v1"
  end

  test "a credential from the environment rides the opts (and the base_url is kept)" do
    System.put_env("OLLAMA_API_KEY", "secret")

    assert {:ok, _input, opts} = Request.build("ollama:qwen3:14b", @provider_cfg)
    assert opts[:api_key] == "secret"
    assert opts[:base_url] == "http://localhost:11434/v1"
  end

  test "a nil provider config is treated as empty (native fallback)" do
    assert {:ok, "ollama:qwen3:14b", _opts} = Request.build("ollama:qwen3:14b", nil)
  end

  test "an unknown provider fails closed" do
    assert {:error, {:bad_entry, msg}} =
             Request.build("definitely_not_a_provider:model", %{})

    assert msg =~ "definitely_not_a_provider"
  end

  test "an unsupported indirection target fails closed" do
    cfg = %{"providers" => %{"bad" => %{"provider" => "nonexistent_xyz"}}}
    assert {:error, {:bad_entry, msg}} = Request.build("bad:model", cfg)
    assert msg =~ "nonexistent_xyz"
  end

  test "a nil or empty model fails closed, never raises" do
    assert {:error, _} = Request.build(nil, %{})
    assert {:error, _} = Request.build("", %{})
  end

  test "sets the transport receive_timeout so the turn never inherits req_llm's 30s (ADR 041)" do
    assert {:ok, _input, opts} = Request.build("ollama:qwen3:14b", %{})
    assert opts[:receive_timeout] == CodingAgent.Core.Config.provider_receive_timeout_ms()
    assert opts[:receive_timeout] > 30_000
  end
end
