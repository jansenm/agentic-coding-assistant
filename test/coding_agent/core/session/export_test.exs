defmodule CodingAgent.Core.Session.ExportTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session.Export
  alias CodingAgent.Core.Session.Store

  @tmp_root System.tmp_dir!() |> Path.join("agent-export-#{System.unique_integer()}")
  @store_path Path.join(@tmp_root, "store.db")
  @prev Application.compile_env(:coding_agent, :store_path)

  setup do
    Application.put_env(:coding_agent, :store_path, @store_path)
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)

    on_exit(fn ->
      Application.put_env(:coding_agent, :store_path, @prev)
      File.rm_rf!(@tmp_root)
    end)

    :ok
  end

  defp seed(id) do
    state =
      CodingAgent.Core.Session.State.new(
        id: id,
        context: ReqLLM.Context.new(),
        model: "ollama:test-model",
        status: :idle,
        scope_root: @tmp_root
      )

    :ok = Store.save(state)
    :ok = Store.append_display(id, :user, "please review the parser")
    :ok = Store.append_display(id, :reasoning, "let me check the module")
    :ok = Store.append_display(id, :assistant, "I will look", agent: "build")

    :ok =
      Store.append_display(id, :tool, "defmodule Parser do",
        meta: {:tool, "read_file", %{"path" => "lib/parser.ex"}}
      )

    id
  end

  describe "data/1" do
    test "collects redacted metadata and the display view" do
      id = seed("exp-#{System.unique_integer([:positive])}")

      assert {:ok, data} = Export.data(id)
      assert data.id == id
      assert data.model == "ollama:test-model"
      assert data.status == :idle

      assert [%{kind: :user}, %{kind: :reasoning}, %{kind: :assistant}, %{kind: :tool}] =
               data.entries

      # redaction: nothing that could carry a secret
      refute Map.has_key?(data, :provider_config)
      refute Map.has_key?(data, :policy)
    end

    test "a missing session errors" do
      assert {:error, :enoent} = Export.data("nope-#{System.unique_integer([:positive])}")
    end
  end

  describe "to_json/1" do
    test "renders a JSON document with tool arguments intact" do
      id = seed("exp-json-#{System.unique_integer([:positive])}")
      {:ok, data} = Export.data(id)

      decoded = data |> Export.to_json() |> Jason.decode!()

      assert decoded["id"] == id
      assert decoded["model"] == "ollama:test-model"
      assert decoded["status"] == "idle"
      assert is_binary(decoded["saved_at"])

      tool = Enum.find(decoded["entries"], &(&1["kind"] == "tool"))
      assert tool["tool"] == "read_file"
      assert tool["arguments"] == %{"path" => "lib/parser.ex"}

      # the agent attribution survives on the assistant row
      assistant = Enum.find(decoded["entries"], &(&1["kind"] == "assistant"))
      assert assistant["agent"] == "build"
    end

    test "is valid JSON even when metadata fields are nil" do
      id = "exp-nil-#{System.unique_integer([:positive])}"

      state =
        CodingAgent.Core.Session.State.new(
          id: id,
          context: ReqLLM.Context.new(),
          model: nil,
          status: :idle,
          scope_root: nil
        )

      :ok = Store.save(state)
      {:ok, data} = Export.data(id)

      assert %{"model" => nil, "scope_root" => nil} = data |> Export.to_json() |> Jason.decode!()
    end
  end

  describe "to_markdown/1" do
    test "renders a readable transcript with tool arguments and results" do
      id = seed("exp-md-#{System.unique_integer([:positive])}")
      {:ok, data} = Export.data(id)

      md = Export.to_markdown(data)

      assert md =~ "# Session #{id}"
      assert md =~ "- model: ollama:test-model"
      assert md =~ "## user"
      assert md =~ "please review the parser"
      assert md =~ "### reasoning"
      assert md =~ "## assistant (build)"
      assert md =~ "### tool: read_file"
      assert md =~ ~s("path": "lib/parser.ex")
      assert md =~ "defmodule Parser do"
      # it says plainly that it is not resumable
      assert md =~ "not a resumable session"
    end
  end
end
