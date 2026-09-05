defmodule CodingAgent.Core.PathHardeningTest do
  @moduledoc """
  Security guard tests for path containment (ADR 002 trust model).

  These tests exist so that nobody can accidentally reopen the symlink
  or traversal holes. They attack `in_scope?/2` directly (the single
  audit point every tool must pass) and via a real tool; if you are here
  because one of them fails after a refactor: the old behavior leaked
  /etc/passwd through a symlinked directory (see ADR 002, about-tools).

  Every case could once read /etc/passwd or an outside file — do not
  weaken these without an ADR.
  """

  use ExUnit.Case, async: true

  # Runs the guard at the tool-registry API level; eventually all tools
  # must go through Tools.in_scope?/2 — these tests pin that contract.
  alias CodingAgent.Core.Tools

  setup do
    root = Path.join(System.tmp_dir!(), "hardening-#{System.unique_integer()}")
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "docs/inside.txt"), "inside")

    secret = Path.join(System.tmp_dir!(), "hardening-secret-#{System.unique_integer()}")
    File.mkdir_p!(secret)
    File.write!(Path.join(secret, "shadow"), "SECRET")

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(secret)
    end)

    %{root: root, secret_file: Path.join(secret, "shadow"), secret_dir: secret}
  end

  # idempotent: remove a colliding leftover from a previous run first
  defp symlink(target, link) do
    _ = :file.del_dir_r(link)
    _ = File.rm(link)
    :ok = :file.make_symlink(String.to_charlist(target), String.to_charlist(link))
  end

  # -- The audit point itself ----------------------------------------------------

  describe "Tools.in_scope?/2" do
    test "rejects dot-dot traversal", %{root: root} do
      scope = %{root: root}
      refute Tools.in_scope?(scope, "../etc/passwd")
      refute Tools.in_scope?(scope, "docs/../../../etc/passwd")
      refute Tools.in_scope?(scope, "docs/../../../../../etc/passwd")
    end

    test "rejects absolute paths outside", %{root: root} do
      scope = %{root: root}
      refute Tools.in_scope?(scope, "/etc/passwd")
      refute Tools.in_scope?(scope, "/tmp")
      assert Tools.in_scope?(scope, root)
    end

    test "rejects symlinked file pointing outside", %{root: root, secret_file: secret} do
      symlink(secret, Path.join(root, "leak.txt"))
      refute Tools.in_scope?(%{root: root}, "leak.txt")
    end

    test "rejects symlinked DIRECTORY pointing outside (file and subdir behind it)",
         %{root: root, secret_dir: secret} do
      symlink(secret, Path.join(root, "outside"))
      refute Tools.in_scope?(%{root: root}, "outside")
      refute Tools.in_scope?(%{root: root}, "outside/shadow")
      refute Tools.in_scope?(%{root: root}, "outside/deeper/still")
    end

    test "rejects chained symlinks that end outside", %{root: root, secret_file: secret} do
      symlink(secret, Path.join(root, "first"))
      symlink(Path.join(root, "first"), Path.join(root, "second"))
      refute Tools.in_scope?(%{root: root}, "second")
    end

    test "dot-dot INSIDE a symlinked path is still normalized then checked", %{
      root: root,
      secret_dir: secret
    } do
      # link -> secret dir (outside); resolution must follow it then
      # re-check containment of everything after dot-dot
      symlink(secret, Path.join(root, "out"))
      refute Tools.in_scope?(%{root: root}, "out")
      refute Tools.in_scope?(%{root: root}, "out/shadow")
      refute Tools.in_scope?(%{root: root}, "docs/../out/shadow")
    end

    test "accepts legitimate in-scope paths", %{root: root} do
      scope = %{root: root}
      assert Tools.in_scope?(scope, "docs/inside.txt")
      assert Tools.in_scope?(scope, "docs/")
      assert Tools.in_scope?(scope, ".")
      assert Tools.in_scope?(scope, "docs/new-file-that-does-not-exist.txt")
    end

    test "accepts internal symlinks and symlinked scope root", %{
      root: root,
      secret_file: secret
    } do
      scope = %{root: root}
      # internal link: resolves inside
      symlink(Path.join(root, "docs/inside.txt"), Path.join(root, "alias.txt"))
      assert Tools.in_scope?(scope, "alias.txt")
      refute File.read!(secret) == nil

      # the practical case: the workspace root itself given as a
      # symlink is fine (the root is resolved first)
      pristine = Path.join(System.tmp_dir!(), "hardening-resolved-#{System.unique_integer()}")
      File.mkdir_p!(Path.join(pristine, "sub"))
      symlink(pristine, root <> "-viacwd")

      assert Tools.in_scope?(%{root: root <> "-viacwd"}, "sub/anything")
    end

    test "rejects candidate through symlinked ancestor with dot-dot", %{
      root: root,
      secret_dir: secret
    } do
      symlink(secret, Path.join(root, "jump"))
      # after resolving jump -> secret, ../.. lands outside
      refute Tools.in_scope?(%{root: root}, "jump/x/../x")
    end

    test "write-style path (missing final file) behind symlinked dir is rejected",
         %{root: root, secret_dir: secret} do
      symlink(secret, Path.join(root, "jump"))
      refute Tools.in_scope?(%{root: root}, "jump/newfile.txt")
    end
  end

  # -- Through the actual tools (integration) -------------------------------------

  describe "read_file tool containment" do
    test "leak attempts all fail with a scope error", %{root: root, secret_file: secret} do
      symlink(secret, Path.join(root, "leak.txt"))
      symlink(secret, Path.join(root, "leakdir"))
      tool = find("read_file", root)

      for path <- ["leak.txt", "/etc/passwd", "../../../etc/passwd"] do
        # containment may reject with a scope error (string) or fail the
        # callback (exception struct) — both mean "did not read".
        {:error, msg} = ReqLLM.Tool.execute(tool, %{"path" => path})
        text = if is_binary(msg), do: msg, else: Exception.message(msg)
        assert text != "", "path #{path}"
        # the secret content must not appear in any error
        refute text =~ "SECRET", "path #{path}"
      end
    end

    test "in-scope reads still work", %{root: root} do
      tool = find("read_file", %{root: root})
      assert {:ok, "inside"} = ReqLLM.Tool.execute(tool, %{"path" => "docs/inside.txt"})
    end
  end

  defp find(name, scope) do
    Enum.find(Tools.all(scope), &(&1.name == name))
  end
end
