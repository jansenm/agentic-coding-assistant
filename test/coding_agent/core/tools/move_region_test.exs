defmodule CodingAgent.Core.Tools.MoveRegionTest do
  @moduledoc """
  `move_region` through the real tool surface (the suite's confining double
  stands in for bwrap here; the real confinement is asserted in the bwrap
  integration tests). The computation itself is pinned in
  `test/coding_agent/core/region_test.exs` — these tests are about what
  reaches the filesystem.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.MoveRegion

  setup do
    root = Path.join(System.tmp_dir!(), "agent-region-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "from.ex"), """
    defmodule A do
      alias CodingAgent.Core.X

      defp one do
        1
      end

      defp two do
        2
      end
    end
    """)

    File.write!(Path.join(root, "to.ex"), """
    defmodule B do
    end
    """)

    %{scope: %{root: root}, root: root}
  end

  defp find_tool(scope) do
    Enum.find(Tools.all(scope), &(&1.name == "move_region"))
  end

  defp move(scope, args) do
    ReqLLM.Tool.execute(find_tool(scope), args)
  end

  test "it is registered as a gated, allow-by-default tool" do
    tool = find_tool(%{root: File.cwd!()})
    assert tool != nil
    assert CodingAgent.Core.Permissions.default_for("move_region") == :allow
  end

  test "a cross-file move writes both files", %{scope: scope, root: root} do
    assert {:ok, out} =
             move(scope, %{
               "from_path" => "from.ex",
               "to_path" => "to.ex",
               "from" => "defp two do",
               "to" => "end",
               "position" => ":end"
             })

    assert out =~ "moved 3 line(s)"
    assert out =~ "mix format"

    source = File.read!(Path.join(root, "from.ex"))
    dest = File.read!(Path.join(root, "to.ex"))

    refute source =~ "defp two"
    assert source =~ "defp one"
    assert dest =~ "defp two do"
    assert dest =~ "2"
  end

  test "a dry run writes nothing", %{scope: scope, root: root} do
    before_from = File.read!(Path.join(root, "from.ex"))
    before_to = File.read!(Path.join(root, "to.ex"))

    assert {:ok, out} =
             move(scope, %{
               "from_path" => "from.ex",
               "to_path" => "to.ex",
               "from" => "defp two do",
               "to" => "end",
               "position" => ":end",
               "dry_run" => true
             })

    assert out =~ "dry run"
    assert out =~ "nothing written"
    assert File.read!(Path.join(root, "from.ex")) == before_from
    assert File.read!(Path.join(root, "to.ex")) == before_to
  end

  test "a same-file reorder rewrites the one file", %{scope: scope, root: root} do
    assert {:ok, out} =
             move(scope, %{
               "from_path" => "from.ex",
               "to_path" => "from.ex",
               "from" => "defp two do",
               "to" => "end",
               "position" => ":begin"
             })

    assert out =~ "moved 3 line(s)"

    body = File.read!(Path.join(root, "from.ex"))
    {two, _} = :binary.match(body, "defp two")
    {one, _} = :binary.match(body, "defp one")
    assert two < one
    # the temp file does not survive the rename
    refute File.exists?(Path.join(root, "from.ex.move-tmp"))
  end

  # A position that resolves INSIDE the region is refused. The anchor has
  # to be unique first ("end" is not — the ambiguity check fires before
  # this one), so this uses the function's own body line.
  test "a same-file move to a position inside the region is refused", %{scope: scope, root: root} do
    before = File.read!(Path.join(root, "from.ex"))

    assert {:error, message} =
             move(scope, %{
               "from_path" => "from.ex",
               "to_path" => "from.ex",
               "from" => "defp two do",
               "to" => "end",
               "position" => "after: 2"
             })

    assert message =~ "lands inside the region"
    assert File.read!(Path.join(root, "from.ex")) == before
  end

  # The rollback: the destination is written first, so a failing source
  # write must put the destination back to exactly what it held.
  test "a failed source write restores the destination", %{scope: scope, root: root} do
    before_to = File.read!(Path.join(root, "to.ex"))
    source_path = Path.join(root, "from.ex")
    File.chmod!(source_path, 0o444)
    on_exit(fn -> File.chmod(source_path, 0o644) end)

    assert {:error, message} =
             move(scope, %{
               "from_path" => "from.ex",
               "to_path" => "to.ex",
               "from" => "defp two do",
               "to" => "end",
               "position" => ":end"
             })

    assert message =~ "moved nothing"
    assert message =~ "restored to its original content"
    assert File.read!(Path.join(root, "to.ex")) == before_to
  end

  test "the parse guard refuses a partial region and writes nothing", %{scope: scope, root: root} do
    before_from = File.read!(Path.join(root, "from.ex"))
    before_to = File.read!(Path.join(root, "to.ex"))

    assert {:error, message} =
             move(scope, %{
               "from_path" => "from.ex",
               "to_path" => "to.ex",
               "from" => "defp two do",
               "to" => "2",
               "position" => ":end"
             })

    assert message =~ "does not parse"
    assert File.read!(Path.join(root, "from.ex")) == before_from
    assert File.read!(Path.join(root, "to.ex")) == before_to
  end

  test "its position spellings are parsed, and a bad one names the four", %{scope: scope} do
    assert {:ok, :begin} = MoveRegion.parse_position(":begin")
    assert {:ok, {:before, "x"}} = MoveRegion.parse_position("before: x")
    assert {:ok, {:after, "x"}} = MoveRegion.parse_position("after:x")
    assert {:error, message} = MoveRegion.parse_position("sideways")
    assert message =~ ":begin"
    assert message =~ "\"after: <anchor>\""

    assert {:error, message} =
             move(scope, %{
               "from_path" => "from.ex",
               "to_path" => "to.ex",
               "from" => "defp two do",
               "to" => "end",
               "position" => "sideways"
             })

    assert message =~ "position must be"
  end

  test "a missing source file is a refusal, not a crash", %{scope: scope} do
    assert {:error, message} =
             move(scope, %{
               "from_path" => "nope.ex",
               "to_path" => "to.ex",
               "from" => "x",
               "to" => "x",
               "position" => ":end"
             })

    assert message =~ "no such file"
  end
end
