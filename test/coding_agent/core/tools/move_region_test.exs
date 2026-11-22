# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

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

  # N133: `a.ex` and `./a.ex` are one file. Decided on the resolved path, so
  # the move is a REORDER of one file, not two writes into it (which put the
  # source text last and lost the region, while reporting success).
  test "two spellings of one path are one file", %{scope: scope, root: root} do
    assert {:ok, out} =
             move(scope, %{
               "from_path" => "from.ex",
               "to_path" => "./from.ex",
               "from" => "defp two do",
               "to" => "end",
               "position" => ":begin"
             })

    assert out =~ "moved 3 line(s)"

    body = File.read!(Path.join(root, "from.ex"))
    {two, _} = :binary.match(body, "defp two")
    {one, _} = :binary.match(body, "defp one")
    assert two < one
    # the region appears exactly once: a cross-file move into the same file
    # left it at BOTH names' text (the second write overwrote the first)
    assert length(:binary.matches(body, "defp two")) == 1
    assert length(:binary.matches(body, "defp one")) == 1
  end

  # The same class, one layer down: a symlink is one file under two names that
  # no path comparison can see. The two writes then collide, so the move must
  # notice AFTER the fact and put the file back — not report a success.
  test "a symlink alias of the source is refused, and the file is put back", %{
    scope: scope,
    root: root
  } do
    before_from = File.read!(Path.join(root, "from.ex"))
    File.ln_s!(Path.join(root, "from.ex"), Path.join(root, "alias.ex"))

    assert {:error, message} =
             move(scope, %{
               "from_path" => "from.ex",
               "to_path" => "alias.ex",
               "from" => "defp two do",
               "to" => "end",
               "position" => ":begin"
             })

    assert message =~ "SAME file under two names"
    assert message =~ "Nothing was moved"
    assert File.read!(Path.join(root, "from.ex")) == before_from
  end

  # A hardlink is the same collision without a link to see: both names are real
  # paths, both hold the same inode.
  test "a hardlink alias of the source is refused, and the file is put back", %{
    scope: scope,
    root: root
  } do
    before_from = File.read!(Path.join(root, "from.ex"))
    File.ln!(Path.join(root, "from.ex"), Path.join(root, "hard.ex"))

    assert {:error, message} =
             move(scope, %{
               "from_path" => "from.ex",
               "to_path" => "hard.ex",
               "from" => "defp two do",
               "to" => "end",
               "position" => ":begin"
             })

    assert message =~ "SAME file under two names"
    assert File.read!(Path.join(root, "from.ex")) == before_from
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

  # N136: the undo has to tell "there was no destination" from "there was an
  # EMPTY one". The old `read_or_empty/3` mapped both to `""`, so the undo
  # removed a file this call had not created. `e9ef88f` introduced
  # `%{text:, existed?:}`, which closes it — this pins the distinction,
  # because the three tests that commit added are all about ALIASES and none
  # of them reaches the rollback.
  test "a failed source write restores an EMPTY destination instead of deleting it", %{
    scope: scope,
    root: root
  } do
    empty = Path.join(root, "empty.ex")
    File.write!(empty, "")
    source_path = Path.join(root, "from.ex")
    File.chmod!(source_path, 0o444)
    on_exit(fn -> File.chmod(source_path, 0o644) end)

    assert {:error, message} =
             move(scope, %{
               "from_path" => "from.ex",
               "to_path" => "empty.ex",
               "from" => "defp two do",
               "to" => "end",
               "position" => ":end"
             })

    assert message =~ "moved nothing"
    # the wording is the other half of the finding: "removed again" would be
    # a lie about a file that existed before the call
    assert message =~ "restored to its original content"
    assert File.exists?(empty)
    assert File.read!(empty) == ""
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
