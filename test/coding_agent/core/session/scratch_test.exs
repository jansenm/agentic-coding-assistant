# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.ScratchTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Session.Scratch

  @id "scratch-test-#{System.unique_integer([:positive])}"

  setup do
    dir = Scratch.path(@id)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "path lives under the tmp base, per session" do
    assert Scratch.path(@id) == Path.join(Scratch.base_dir(), @id)
    assert String.starts_with?(Scratch.path(@id), System.tmp_dir!())
    assert Scratch.base_dir() == Path.join(System.tmp_dir!(), "coding-agent")
  end

  test "from_scope derives the path from a session id, nil otherwise" do
    assert Scratch.from_scope(%{root: "/x", session_id: @id}) == Scratch.path(@id)
    assert Scratch.from_scope(%{root: "/x", session_id: nil}) == nil
    assert Scratch.from_scope(%{root: "/x"}) == nil
    assert Scratch.from_scope(%{root: "/x", session_id: ""}) == nil
    assert Scratch.from_scope(%{root: "/x", session_id: 123}) == nil
  end

  test "ensure creates the directory (idempotent), remove drops it", %{dir: dir} do
    refute File.dir?(dir)

    assert {:ok, ^dir} = Scratch.ensure(dir)
    assert File.dir?(dir)

    # idempotent — a file inside survives a second ensure
    File.write!(Path.join(dir, "keep.txt"), "x")
    assert {:ok, ^dir} = Scratch.ensure(dir)
    assert File.read!(Path.join(dir, "keep.txt")) == "x"

    assert :ok = Scratch.remove(dir)
    refute File.dir?(dir)
  end

  test "remove on a missing directory is a no-op" do
    assert :ok = Scratch.remove(Scratch.path("never-created-#{System.unique_integer()}"))
  end

  test "move relocates a session's scratch; missing source is fine", %{dir: dir} do
    other = Scratch.path("moved-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(other) end)

    # missing source: no crash, no target
    assert :ok = Scratch.move(dir, other)
    refute File.dir?(other)

    Scratch.ensure(dir)
    File.write!(Path.join(dir, "f"), "data")
    assert :ok = Scratch.move(dir, other)
    refute File.dir?(dir)
    assert File.read!(Path.join(other, "f")) == "data"
  end
end
