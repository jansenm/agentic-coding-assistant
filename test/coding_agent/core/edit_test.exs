defmodule CodingAgent.Core.Tools.EditTest do
  use ExUnit.Case, async: true

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
      # the matching lines, so the model widens without a re-read
      assert msg =~ "on lines 3, 4"
      # file untouched
      assert File.read!(Path.join(@root, "code.ex")) =~ "def two, do: 2"
      assert File.read!(Path.join(@root, "code.ex")) =~ "def two_again, do: 22"
    end

    test "ambiguity lists the matching lines in order", %{tool: tool} do
      File.write!(Path.join(@root, "many.txt"), "x\nax\nb\nax\nc\nax\n")

      {:error, msg} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "many.txt",
          "old_string" => "ax",
          "new_string" => "y"
        })

      assert msg =~ "3 matches on lines 2, 4, 6"
    end

    test "ambiguity stops at ten lines and says possibly more", %{tool: tool} do
      File.write!(Path.join(@root, "twelve.txt"), String.duplicate("ax\n", 12))

      {:error, msg} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "twelve.txt",
          "old_string" => "ax",
          "new_string" => "y"
        })

      assert msg =~ "12 matches on lines 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, possibly more lines"
      refute msg =~ "11,"
    end

    test "ambiguity at exactly ten lines does not claim more", %{tool: tool} do
      File.write!(Path.join(@root, "ten.txt"), String.duplicate("ax\n", 10))

      {:error, msg} =
        ReqLLM.Tool.execute(tool, %{
          "path" => "ten.txt",
          "old_string" => "ax",
          "new_string" => "y"
        })

      assert msg =~ "lines 1, 2, 3, 4, 5, 6, 7, 8, 9, 10;"
      refute msg =~ "possibly more"
    end

    test "every refusal leaves the file byte-identical", %{tool: tool} do
      untouched = File.read!(Path.join(@root, "code.ex"))

      for old <- ["def two", "def nope", "def one, do: 1\n  def one, do: 1"] do
        assert {:error, _} =
                 ReqLLM.Tool.execute(tool, %{
                   "path" => "code.ex",
                   "old_string" => old,
                   "new_string" => "z"
                 })
      end

      assert File.read!(Path.join(@root, "code.ex")) == untouched
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
    test "edit defaults to allow-by-policy (ADR 010 amendment): a contained edit runs without a pause" do
      policy = Permissions.load(nil, nil)
      assert Permissions.effective(policy, "edit", "code.ex", "default") == :allow

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

      # the amendment's acceptance: NO interruption — debug_gate leaves
      # the synthetic :running status (no LLM loop in test mode), what
      # matters is there is no parked approval
      {:ok, state} = Session.state(id)
      refute state.status == :interrupted
      assert state.pending_tool_calls == []
      assert File.read!(Path.join(@root, "code.ex")) =~ "def one, do: :one"
    end

    test "a repo-side [permissions.edit] entry still pauses (policy above the class default)" do
      policy_path = Path.join(@root, "permissions.toml")

      File.write!(policy_path, """
      [permissions.edit]
      "*" = "ask"
      """)

      policy = Permissions.load(nil, policy_path)

      id = "edit-gate-ask-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @root,
          policy: policy,
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
    end

    test "reject path still leaves the file alone (approve/reject round-trip under an ask policy)" do
      policy_path = Path.join(@root, "permissions.toml")

      File.write!(policy_path, """
      [permissions.edit]
      "*" = "ask"
      """)

      policy = Permissions.load(nil, policy_path)

      id = "edit-gate-#{System.unique_integer()}"

      {:ok, _} =
        CodingAgent.Core.Session.Supervisor.start_session(
          id: id,
          scope_root: @root,
          policy: policy,
          test_mode: true
        )

      :ok =
        Session.debug_gate(id, [
          %{
            id: "e2",
            name: "edit",
            arguments: %{
              "path" => "code.ex",
              "old_string" => "def one, do: 1",
              "new_string" => "DESTROY"
            }
          }
        ])

      {:ok, _} = Session.decide(id, [%{id: "e2", decision: :reject}])
      assert File.read!(Path.join(@root, "code.ex")) =~ "def one, do: 1"
      refute File.read!(Path.join(@root, "code.ex")) =~ "DESTROY"
    end
  end
end
