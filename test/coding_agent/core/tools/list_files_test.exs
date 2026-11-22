# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.ListFilesTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.External
  alias CodingAgent.Core.Tools.ListFiles

  @root System.tmp_dir!() |> Path.join("agent-listfiles-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@root)
    File.mkdir_p!(@root)
    File.mkdir_p!(Path.join(@root, "lib"))
    File.mkdir_p!(Path.join(@root, ".github/workflows"))
    File.mkdir_p!(Path.join(@root, "_build"))
    File.write!(Path.join(@root, "lib/a.ex"), "a\n")
    File.write!(Path.join(@root, "lib/b.ex"), "b\n")
    File.write!(Path.join(@root, "README.md"), "x\n")
    File.write!(Path.join(@root, ".github/workflows/ci.yml"), "on: push\n")
    File.write!(Path.join(@root, ".gitignore"), "/_build\n")
    File.write!(Path.join(@root, "_build/junk.ex"), "j\n")

    on_exit(fn -> File.rm_rf!(@root) end)
    %{scope: %{root: @root}}
  end

  test "lists files, skips the shared skip dirs, hidden included", %{scope: scope} do
    if External.available?(:fd) do
      assert {:ok, files} = ListFiles.list(scope)

      assert "lib/a.ex" in files
      assert "README.md" in files
      # the list carries hidden entries; the FILTER decides visibility
      assert ".github/workflows/ci.yml" in files
      assert ".gitignore" in files
      # the shared skip list prunes _build
      refute Enum.any?(files, &String.starts_with?(&1, "_build/"))
    else
      :ok
    end
  end

  test "filter hides hidden entries unless the query names one", %{scope: scope} do
    if External.available?(:fd) do
      {:ok, files} = ListFiles.list(scope)

      plain = ListFiles.filter(files, "e")
      refute ".gitignore" in plain
      refute Enum.any?(plain, &String.starts_with?(&1, ".github/"))

      named = ListFiles.filter(files, ".github")
      assert Enum.any?(named, &String.starts_with?(&1, ".github/"))
    else
      :ok
    end
  end

  test "filter narrows by case-insensitive substring", %{scope: scope} do
    if External.available?(:fd) do
      {:ok, files} = ListFiles.list(scope)
      assert ListFiles.filter(files, "readme") == ["README.md"]
      assert ListFiles.filter(files, "lib/") == ["lib/a.ex", "lib/b.ex"]
    else
      :ok
    end
  end

  test "a missing fd is an explicit error, not an empty list" do
    saved = External.probe(:fd)
    External.put(:fd, :error)
    on_exit(fn -> External.put(:fd, saved) end)

    assert {:error, :fd_unavailable} = ListFiles.list(%{root: @root})
    assert ListFiles.error_message(:fd_unavailable) =~ "fd was not found"
  end
end
