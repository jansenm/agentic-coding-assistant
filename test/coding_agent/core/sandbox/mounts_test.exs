defmodule CodingAgent.Core.Sandbox.MountsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Sandbox.Mounts

  describe "resolve/1 non-elevation" do
    test "rw is taken from shipped and global, but never from the project layer" do
      shipped = %{"sandbox" => %{"rw" => ["/srv/cache"]}}
      global = %{"sandbox" => %{"rw" => ["/home/me/cache"]}}
      project = %{"sandbox" => %{"rw" => ["/repo/evil"]}}

      mounts = Mounts.resolve([shipped, global, project])

      assert mounts.rw == ["/home/me/cache", "/srv/cache"]
      refute "/repo/evil" in mounts.rw
    end

    test "ro and hide are unioned across all three layers" do
      shipped = %{"sandbox" => %{"ro" => ["/a"]}}
      global = %{"sandbox" => %{"hide" => ["~/.ssh"]}}
      project = %{"sandbox" => %{"ro" => ["/b"], "hide" => ["/repo/secret"]}}

      mounts = Mounts.resolve([shipped, global, project])

      assert "/a" in mounts.ro
      assert "/b" in mounts.ro
      home = System.get_env("HOME")
      assert Path.join(home, ".ssh") in mounts.hide
      assert "/repo/secret" in mounts.hide
    end

    test "a project layer cannot add rw even alongside its own ro" do
      project = %{"sandbox" => %{"rw" => ["/repo/x"], "ro" => ["/repo/y"]}}

      mounts = Mounts.resolve([%{}, %{}, project])

      assert mounts.rw == []
      assert mounts.ro == ["/repo/y"]
    end

    test "missing sandbox section yields empty mounts" do
      assert Mounts.resolve([%{}, %{}, %{}]) == %{rw: [], ro: [], hide: []}
    end

    test "non-list and non-binary entries are dropped" do
      layer = %{"sandbox" => %{"rw" => ["/ok", 42, nil], "ro" => "not a list"}}

      assert Mounts.resolve([layer, %{}, %{}]).rw == ["/ok"]
      assert Mounts.resolve([layer, %{}, %{}]).ro == []
    end

    test "relative paths are rejected; absolute and ~ are kept" do
      layer = %{"sandbox" => %{"rw" => ["relative/path", "/abs", "~/x"]}}

      mounts = Mounts.resolve([%{}, layer, %{}])

      assert "/abs" in mounts.rw
      assert Path.join(System.get_env("HOME"), "x") in mounts.rw
      refute "relative/path" in mounts.rw
    end

    test "duplicates are removed and output is sorted" do
      layer = %{"sandbox" => %{"ro" => ["/b", "/a", "/b"]}}

      assert Mounts.resolve([layer, layer, %{}]).ro == ["/a", "/b"]
    end

    test "a hide entry below another hide entry is pruned" do
      layer = %{"sandbox" => %{"hide" => ["/a/b", "/a"]}}

      assert Mounts.resolve([%{}, %{}, layer]).hide == ["/a"]
    end

    test "pruning compares path components, not string prefixes" do
      # `/a/bc` and `/a/b` are SIBLINGS, not ancestor and child: a prefix
      # test (`String.starts_with?/2` → true) would drop `/a/bc`'s hide
      # and leave it visible while its neighbour is hidden.
      layer = %{"sandbox" => %{"hide" => ["/a/b", "/a/bc"]}}

      assert Mounts.resolve([%{}, %{}, layer]).hide == ["/a/b", "/a/bc"]
    end

    test "only hide is pruned: ro and rw keep their nested entries" do
      layer = %{"sandbox" => %{"ro" => ["/a", "/a/b"], "rw" => ["/c", "/c/d"]}}

      mounts = Mounts.resolve([layer, %{}, %{}])

      assert mounts.ro == ["/a", "/a/b"]
      assert mounts.rw == ["/c", "/c/d"]
    end
  end

  describe "eligible?/1" do
    test "accepts absolute and ~ paths" do
      assert Mounts.eligible?("/etc")
      assert Mounts.eligible?("~/x")
    end

    test "rejects relative, empty and non-binary" do
      refute Mounts.eligible?("foo/bar")
      refute Mounts.eligible?("")
      refute Mounts.eligible?(nil)
      refute Mounts.eligible?(42)
    end
  end
end
