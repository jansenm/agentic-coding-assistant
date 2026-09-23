defmodule CodingAgent.Core.ContainmentTest do
  use ExUnit.Case, async: true

  # The guard tests for THE containment walk. These attacks target the
  # single implementation in Containment — the same mistakes were made
  # twice in slice 2d (grep walked into an out-of-scope symlinked dir;
  # glob listed a symlinked out-file). Do not weaken without an ADR.

  alias CodingAgent.Core.Containment

  @root System.tmp_dir!() |> Path.join("agent-contain-#{System.unique_integer()}")
  @outside System.tmp_dir!() |> Path.join("agent-contain-out-#{System.unique_integer()}")

  setup do
    File.rm_rf!(@root)
    File.rm_rf!(@outside)
    File.mkdir_p!(@outside)
    File.mkdir_p!(Path.join(@root, "src"))
    File.write!(Path.join(@root, "src/inside.txt"), "in\n")
    File.write!(Path.join(@root, "top.txt"), "top\n")
    File.write!(Path.join(@outside, "secret.txt"), "SECRET\n")
    File.mkdir_p!(Path.join(@outside, "deep"))

    on_exit(fn ->
      File.rm_rf!(@root)
      File.rm_rf!(@outside)
    end)

    scope = %{root: @root}
    %{scope: scope}
  end

  describe "path_allowed?/2 (predicate)" do
    test "in-scope paths pass", %{scope: scope} do
      assert Containment.path_allowed?(scope, "src/inside.txt")
      assert Containment.path_allowed?(scope, "top.txt")
    end

    test "direct escapes fail", %{scope: scope} do
      refute Containment.path_allowed?(scope, "../#{Path.basename(@outside)}")
      refute Containment.path_allowed?(scope, "/etc/passwd")
      refute Containment.path_allowed?(scope, "src/../../../etc/passwd")
    end
  end

  describe "walk/3 — the one walk" do
    test "yields in-scope files in deterministic order", %{scope: scope} do
      files = Containment.walk(scope, ".")

      assert length(files) == 2

      [f1, f2] = files
      assert Path.relative_to(f1, @root) == "src/inside.txt"
      assert Path.relative_to(f2, @root) == "top.txt"
    end

    test "walks into in-scope nested dirs", %{scope: scope} do
      File.mkdir_p!(Path.join(@root, "src/deep"))
      File.write!(Path.join(@root, "src/deep/nested.txt"), "n\n")
      files = Containment.walk(scope, ".")
      assert length(files) == 3
    end

    test "attack: symlinked FILE pointing outside is not yielded", %{scope: scope} do
      :file.make_symlink(
        String.to_charlist(Path.join(@outside, "secret.txt")),
        String.to_charlist(Path.join(@root, "leak-file"))
      )

      files = Containment.walk(scope, ".")
      refute Enum.any?(files, &String.contains?(&1, "leak"))
    end

    test "attack: symlinked DIR pointing outside is not entered", %{scope: scope} do
      :file.make_symlink(
        String.to_charlist(@outside),
        String.to_charlist(Path.join(@root, "leak-dir"))
      )

      files = Containment.walk(scope, ".")
      refute Enum.any?(files, &String.contains?(&1, "leak-dir"))
      refute Enum.any?(files, &String.contains?(&1, @outside))

      # also: no infinite walk (the original bug looped to the hop cap)
      assert Path.dirname(hd(files)) != ""
    end

    test "attack: a symlinked dir *inside* the scope still works", %{scope: scope} do
      :file.make_symlink(
        String.to_charlist(Path.join(@root, "src")),
        String.to_charlist(Path.join(@root, "alias"))
      )

      files = Containment.walk(scope, ".")
      assert Enum.any?(files, &String.contains?(&1, "alias/inside.txt"))
    end

    test "prunes default skip dirs and hidden dirs", %{scope: scope} do
      File.mkdir_p!(Path.join(@root, "_build/prod/lib"))
      File.write!(Path.join(@root, "_build/prod/junk.txt"), "x\n")
      File.mkdir_p!(Path.join(@root, ".hidden"))
      File.write!(Path.join(@root, ".hidden/secret.txt"), "s\n")

      files = Containment.walk(scope, ".")
      refute Enum.any?(files, &String.contains?(&1, "_build"))
      refute Enum.any?(files, &String.contains?(&1, ".hidden/"))
    end

    test ":match_files filters by entry name and scope-relative path", %{scope: scope} do
      File.write!(Path.join(@root, "src/other.ex"), "ex\n")
      File.write!(Path.join(@root, "src/data.json"), "{}\n")

      files =
        Containment.walk(scope, ".",
          match_files: fn name, rel -> String.ends_with?(name, ".ex") and rel != "" end
        )

      names = Enum.map(files, &Path.relative_to(&1, @root))
      assert names == ["src/other.ex"]

      # the second argument is the path RELATIVE TO THE SCOPE ROOT, which
      # is what a `lib/**/*.ex`-style glob needs
      files =
        Containment.walk(scope, ".", match_files: fn _name, rel -> rel == "src/data.json" end)

      assert Enum.map(files, &Path.relative_to(&1, @root)) == ["src/data.json"]

      # no filter means "take everything"
      files = Containment.walk(scope, ".", match_files: nil)

      assert Enum.sort(Enum.map(files, &Path.relative_to(&1, @root))) ==
               ["src/data.json", "src/inside.txt", "src/other.ex", "top.txt"]

      File.rm!(Path.join(@root, "src/other.ex"))
      File.rm!(Path.join(@root, "src/data.json"))
    end

    test ":max_entries caps the walk", %{scope: scope} do
      for i <- 1..10, do: File.write!(Path.join(@root, "src/f#{i}.txt"), "x\n")
      files = Containment.walk(scope, ".", max_entries: 3)
      assert length(files) <= 4
    end

    test "single-file path returns [file] when in scope, [] when not", %{scope: scope} do
      assert Containment.walk(scope, "top.txt") == [Path.join(@root, "top.txt")]
      assert Containment.walk(scope, "../#{Path.basename(@outside)}/secret.txt") == []
      assert Containment.walk(scope, "missing.txt") == []
    end

    test "skips unreadable dirs silently", %{scope: scope} do
      File.mkdir_p!(Path.join(@root, "unreadable"))
      File.write!(Path.join(@root, "unreadable/inside.txt"), "x\n")

      # deny read on the dir: running as root would ignore this, so only
      # assert no-crash + the rest of the walk still works
      File.chmod!(Path.join(@root, "unreadable"), 0o000)

      on_exit(fn ->
        File.chmod!(Path.join(@root, "unreadable"), 0o755)
      end)

      files = Containment.walk(scope, ".")
      assert Enum.any?(files, &String.contains?(&1, "top.txt"))
    end

    test "default skips hidden FILES too, not just hidden dirs", %{scope: scope} do
      File.mkdir_p!(Path.join(@root, ".github/workflows"))
      File.write!(Path.join(@root, ".github/workflows/ci.yml"), "on: push\n")
      File.write!(Path.join(@root, ".dotfile"), "x\n")
      File.mkdir_p!(Path.join(@root, "src/.nested"))
      File.write!(Path.join(@root, "src/.nested/deep.txt"), "d\n")

      files = Containment.walk(scope, ".")
      refute Enum.any?(files, &String.contains?(&1, ".github"))
      refute Enum.any?(files, &String.ends_with?(&1, ".dotfile"))
      refute Enum.any?(files, &String.contains?(&1, ".nested"))
      assert Enum.any?(files, &String.ends_with?(&1, "top.txt"))

      # this is the rule that makes the walk agree with rg/fd: they skip a
      # hidden FILE as well, and an unfiltered walk did not (measured)
      assert Enum.sort(Enum.map(files, &Path.relative_to(&1, @root))) ==
               ["src/inside.txt", "top.txt"]
    end

    test ":include_hidden yields hidden files and descends into hidden dirs", %{scope: scope} do
      File.mkdir_p!(Path.join(@root, ".github/workflows"))
      File.write!(Path.join(@root, ".github/workflows/ci.yml"), "on: push\n")
      File.write!(Path.join(@root, ".dotfile"), "x\n")

      files = Containment.walk(scope, ".", include_hidden: true)
      rel = Enum.map(files, &Path.relative_to(&1, @root))

      assert ".github/workflows/ci.yml" in rel
      assert ".dotfile" in rel

      # ...and the skip list still wins: naming a hidden dir does not
      # open .git (the skip list prunes it in both modes)
      File.mkdir_p!(Path.join(@root, ".git/objects"))
      File.write!(Path.join(@root, ".git/objects/blob"), "bin\n")

      files = Containment.walk(scope, ".", include_hidden: true)
      refute Enum.any?(files, &String.contains?(&1, ".git/"))
    end

    test "naming a hidden path is the opt-in, hidden or not", %{scope: scope} do
      File.write!(Path.join(@root, ".gitignore"), "/_build\n")
      File.mkdir_p!(Path.join(@root, ".idea"))
      File.write!(Path.join(@root, ".idea/misc.xml"), "<x/>\n")

      # a named FILE start is yielded as given (same as read_file)
      assert Containment.walk(scope, ".gitignore") == [Path.join(@root, ".gitignore")]

      # a named DIR start is entered as given
      files = Containment.walk(scope, ".idea")
      assert files == [Path.join(@root, ".idea/misc.xml")]

      # neither is reachable by walking without the opt-in
      files = Containment.walk(scope, ".")
      refute Enum.any?(files, &String.ends_with?(&1, ".gitignore"))
      refute Enum.any?(files, &String.contains?(&1, ".idea/"))
    end
  end

  describe "hidden_entry?/1 + hidden_pattern?/1 (the ONE hidden rule)" do
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

  describe "check_scope!/2" do
    test "ok or error tuple", %{scope: scope} do
      assert Containment.check_scope!(scope, "top.txt") == :ok
      assert {:error, msg} = Containment.check_scope!(scope, "../escape")
      assert msg =~ "escapes the session scope"
    end
  end
end
