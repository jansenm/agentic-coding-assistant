defmodule CodingAgent.Core.ProjectMemoryTest do
  @moduledoc """
  Unit tests for the extracted ProjectMemory module (P3). The session
  integration (prompt lands in the context, resume) stays in
  `project_memory_test.exs`; these pin the loader's own policy:
  missing is normal, oversized truncates, unreadable degrades.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Core.ProjectMemory

  setup do
    root = System.tmp_dir!() |> Path.join("pm-unit-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "append/2 adds the section when AGENTS.md exists", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), "Use tabs.\n")
    out = ProjectMemory.append("BASE", root)

    assert out =~ "BASE"
    assert out =~ "Project memory (AGENTS.md)"
    assert out =~ "Use tabs."
  end

  test "append/2 leaves the prompt unchanged when there is no memory" do
    assert ProjectMemory.append("BASE", nil) == "BASE"

    root = System.tmp_dir!() |> Path.join("pm-none-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    assert ProjectMemory.append("BASE", root) == "BASE"
  end

  @tag capture_log: true
  test "an oversized file truncates to the 64 KiB window", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), String.duplicate("x", 100_000))
    out = ProjectMemory.append("BASE", root)

    assert out =~ "Project memory (AGENTS.md)"
    assert byte_size(out) < 100_000
  end

  test "load/1 returns nil and append is safe when AGENTS.md is a directory", %{root: root} do
    File.mkdir_p!(Path.join(root, "AGENTS.md"))
    assert ProjectMemory.load(root) == nil
    assert ProjectMemory.append("BASE", root) == "BASE"
  end

  describe "nested files (monorepo, review T13)" do
    test "walks UP to the git root and concatenates root-first", %{root: root} do
      # git root has AGENTS.md; a nested package (the scope) has its own
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, "AGENTS.md"), "ROOT RULE\n")

      pkg = Path.join(root, "apps/web")
      File.mkdir_p!(pkg)
      File.write!(Path.join(pkg, "AGENTS.md"), "PACKAGE RULE\n")

      out = ProjectMemory.append("BASE", pkg)

      assert out =~ "ROOT RULE"
      assert out =~ "PACKAGE RULE"
      # root first, scope last (general -> specific)
      assert :binary.match(out, "ROOT RULE") < :binary.match(out, "PACKAGE RULE")
      # and the model is told about deeper files it must read itself
      assert out =~ "Deeper files"
    end

    test "a non-git scope reads exactly its own file (no walk)" do
      outside = System.tmp_dir!() |> Path.join("pm-nogit-#{System.unique_integer()}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)
      File.write!(Path.join(outside, "AGENTS.md"), "ONLY MINE\n")

      out = ProjectMemory.append("BASE", outside)
      assert out =~ "ONLY MINE"
      assert ProjectMemory.dirs(outside) == [Path.expand(outside)]
    end

    test "walks past intermediate directories with no AGENTS.md", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, "AGENTS.md"), "ROOT\n")

      deep = Path.join([root, "a", "b", "c"])
      File.mkdir_p!(deep)

      out = ProjectMemory.append("BASE", deep)
      assert out =~ "ROOT"
    end

    test "does NOT collect subdirectories below the scope", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, "AGENTS.md"), "ROOT\n")

      child = Path.join(root, "child")
      File.mkdir_p!(child)
      File.write!(Path.join(child, "AGENTS.md"), "CHILD ONLY\n")

      # scope is the root: the child's file must NOT be pulled in
      out = ProjectMemory.append("BASE", root)
      assert out =~ "ROOT"
      refute out =~ "CHILD ONLY"
    end
  end
end
