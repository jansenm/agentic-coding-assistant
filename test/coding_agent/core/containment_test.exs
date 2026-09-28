defmodule CodingAgent.Core.ContainmentTest do
  use ExUnit.Case, async: true

  # The hidden-entry rule is the vocabulary `grep`/`glob` filter their
  # engine output with (ADR 030). It is no longer a security boundary;
  # these tests guard the one definition both engines share.

  alias CodingAgent.Core.Containment

  describe "default_skip_dirs/0" do
    test "names build/vendor/tool artifacts as a MapSet" do
      dirs = Containment.default_skip_dirs()
      assert MapSet.member?(dirs, "_build")
      assert MapSet.member?(dirs, "deps")
      assert MapSet.member?(dirs, ".git")
    end
  end

  describe "hidden_entry?/1 (the ONE hidden rule)" do
    test "an entry is hidden when any segment starts with a dot" do
      refute Containment.hidden_entry?("lib/a.ex")
      refute Containment.hidden_entry?("README.md")
      assert Containment.hidden_entry?(".gitignore")
      assert Containment.hidden_entry?("docs/.gitignore")
      assert Containment.hidden_entry?(".github/workflows/ci.yml")
      assert Containment.hidden_entry?("src/.secret/key.pem")
    end

    test "'.' and '..' are path syntax, not hidden names" do
      refute Containment.hidden_entry?(".")
      refute Containment.hidden_entry?("./lib/a.ex")
      refute Containment.hidden_entry?("lib/../lib/a.ex")
    end
  end

  describe "hidden_pattern?/1 (the opt-in test)" do
    test "a pattern opts in only when a segment NAMES a hidden entry" do
      refute Containment.hidden_pattern?("**/*.ex")
      refute Containment.hidden_pattern?("*")
      refute Containment.hidden_pattern?("lib/**/*.ex")

      assert Containment.hidden_pattern?(".gitignore")
      assert Containment.hidden_pattern?(".*")
      assert Containment.hidden_pattern?(".idea/*")
      assert Containment.hidden_pattern?("**/.gitconfig")
      assert Containment.hidden_pattern?("docs/.gitkeep")
    end
  end

  describe "filter_hidden/2 + hidden_allowed?/2" do
    test "unnamed hidden entries are dropped, the rest survive" do
      results = ["lib/a.ex", ".gitignore", "src/.secret/key.pem", "top.txt"]
      assert Containment.filter_hidden(results, ["**/*.ex"]) == ["lib/a.ex", "top.txt"]
    end

    test "naming a hidden entry lets hidden results through" do
      results = ["lib/a.ex", ".gitignore", "top.txt"]
      assert Containment.filter_hidden(results, [".gitignore"]) == results
    end

    test "nil names carry no naming" do
      assert Containment.filter_hidden(["lib/a.ex", ".gitignore"], [nil, "."]) == ["lib/a.ex"]
    end

    test "hidden_allowed?/2 is the single predicate behind the filter" do
      assert Containment.hidden_allowed?("lib/a.ex", [])
      refute Containment.hidden_allowed?(".gitignore", [])
      assert Containment.hidden_allowed?(".gitignore", [".*"])
    end
  end
end
