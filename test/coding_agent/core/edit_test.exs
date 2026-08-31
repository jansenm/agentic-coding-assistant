defmodule CodingAgent.Core.Tools.EditTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.Session
  alias CodingAgent.Core.Tools.Edit

  @root System.tmp_dir!() |> Path.join("agent-edit-#{System.unique_integer()}")

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(@root)

    File.write!(Path.join(@root, "code.ex"), """
    defmodule Demo do
      def one, do: 1
      def two, do: 2
      def two_again, do: 22
    end
    """)

    {:ok, tool: Edit.tool(%{root: @root})}
  end

  describe "tool behavior (fail-closed)" do
    test "unique match replaces", %{tool: tool} do
      {:ok, _} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "code.ex",
          "old_string" => "def one, do: 1",
          "new_string" => "def one, do: 11"
        })

      assert File.read!(Path.join(@root, "code.ex")) =~ "def one, do: 1"
    end

    test "ambiguous match refuses (0 replacements happen)", %{tool: tool} do
      {:error, msg} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "code.ex",
          "old_string" => "def two",
          "new_string" => "def three"
        })

      assert msg =~ "ambiguous"
      assert msg =~ "2 matches"
      # file untouched
      assert File.read!(Path.join(@root, "code.ex")) =~ "def two, do: 2"
      assert File.read!(Path.join(@root, "code.ex")) =~ "def two_again, do: 22"
    end

    test "missing match refuses with guidance", %{tool: tool} do
      {:error, msg} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "code.ex",
          "old_string" => "def nope",
          "new_string" => "x"
        })

      assert msg =~ "not found"
      assert msg =~ "re-read"
    end

    test "multiline replacement works", %{tool: tool} do
      {:ok, _} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "code.ex",
          "old_string" => "  def two, do: 2\n  def two_again, do: 22",
          "new_string" => "def two_and_two, do: 4"
        })

      content = File.read!(Path.join(@root, "code.ex"))
      assert content =~ "def two_and_two, do: 4"
      refute content =~ "two_again"
    end

    test "empty old_string creates a new file", %{tool: tool} do
      {:ok, _} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "new_file.txt",
          "old_string" => "",
          "new_string" => "hello"
        })

      assert File.read!(Path.join(@root, "new_file.txt")) == "hello"
    end

    test "empty old_string on existing file refuses", %{tool: tool} do
      {:error, msg} =
        ReqLLM.Tool.execute(tool, %{"path" => "code.ex", "old_string" => "", "new_string" => "x"})

      assert msg =~ "already exists"
      # untouched
      assert File.read!(Path.join(@root, "code.ex")) =~ "defmodule Demo"
    end

    test "edit on missing file refuses", %{tool: tool} do
      {:error, msg} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "ghost.ex",
          "old_string" => "a",
          "new_string" => "b"
        })

      assert msg =~ "no such file"
    end

    test "non-string args refuse (schema validation)", %{tool: tool} do
      assert {:error, %ReqLLM.Error.Validation.Error{}} =
               ReqLLM.Tool.execute(tool, %{"path" => 1, "old_string" => "a", "new_string" => "b"})
    end
  end

  describe "gate integration (ADR 010, LLM-free)" do
    test "edit defaults to :ask; approve path applies; reject does not" do
      policy = Permissions.load(nil, nil)
      assert Permissions.effective(policy, "edit", "code.ex", "default") == :ask

      id = "edit-gate-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @root,
          test_mode: true
        )

      :ok =
        Session.debug_gate(id, [
          %{
            id: "e1",
            name: "edit",
            arguments: %{
              "path" => "code.ex",
              "old_string" => "def one, do: 1",
              "new_string" => "def one, do: :one"
            }
          }
        ])

      {:ok, state} = Session.state(id)
      assert state.status == :interrupted
      # nothing changed yet
      assert File.read!(Path.join(@root, "code.ex")) =~ "def one, do: 1"

      {:ok, _} = Session.decide(id, [%{id: "e1", decision: :approve}])
      assert File.read!(Path.join(@root, "code.ex")) =~ "def one, do: :one"

      # rejection path leaves the file alone
      :ok =
        Session.debug_gate(id, [
          %{
            id: "e2",
            name: "edit",
            arguments: %{
              "path" => "code.ex",
              "old_string" => "def one, do: :one",
              "new_string" => "DESTROY"
            }
          }
        ])

      {:ok, _} = Session.decide(id, [%{id: "e2", decision: :reject}])
      assert File.read!(Path.join(@root, "code.ex")) =~ "def one, do: :one"
      refute File.read!(Path.join(@root, "code.ex")) =~ "DESTROY"
    end
  end
end
