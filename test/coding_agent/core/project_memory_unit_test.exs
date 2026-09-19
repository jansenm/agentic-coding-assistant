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
end
