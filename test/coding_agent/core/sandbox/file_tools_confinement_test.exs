defmodule CodingAgent.Core.Sandbox.FileToolsConfinementTest do
  @moduledoc """
  The LIVE confinement semantics of the native file tools under real
  bwrap (ADR 030): `read_file`, `write_file`, `edit` and `list_dir` are
  confined processes, so the PROFILE decides reach.

  - a `hide`d path is bound to the shipped notice (read-only), so it is
    present, says it is hidden, and cannot be written;
  - a read-only bind (`ro`) is readable but fails with `EROFS` on write;
  - the whole filesystem is readable (`--ro-bind / /`), the scope root
    is the only writable tree;
  - the scope root itself honours `root_ro`.

  Self-skipping when bwrap is unavailable (hardened host / no binary),
  exactly like the other bwrap integration tests: an argv-level test
  still covers the profile build. `async: false`: switches the global
  `:sandbox` app env.
  """
  use ExUnit.Case, async: false

  import CodingAgent.SandboxCase

  alias CodingAgent.Core.Sandbox.Bwrap
  alias CodingAgent.Core.Tools

  @tmp_root System.tmp_dir!()
            |> Path.join("agent-file-conf-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)

    if Bwrap.available?() do
      put_sandbox(Bwrap)
      {:ok, skip: false}
    else
      {:ok, skip: true}
    end
  end

  defp tool(name, scope), do: Enum.find(Tools.all(scope), &(&1.name == name))

  defp scope(root, opts \\ []) do
    %{
      root: root,
      mounts: %{rw: [], ro: Keyword.get(opts, :ro, []), hide: Keyword.get(opts, :hide, [])}
    }
  end

  describe "hide (ADR 030: works for the native tools now)" do
    test "a hidden file reads the notice and cannot be written", %{skip: skip} do
      if skip do
        :ok
      else
        root = ctx_root()
        secret = Path.join(root, "secret.txt")
        File.write!(secret, "TOPSECRET")

        scoped = scope(root, hide: [secret])

        read = tool("read_file", scoped)
        assert {:ok, content} = ReqLLM.Tool.execute(read, %{"path" => "secret.txt"})
        # the notice is bound over the file: the read succeeds and the
        # model is told the path is hidden, not that it is empty
        assert content =~ "Hidden by the harness"
        refute content =~ "TOPSECRET"

        write = tool("write_file", scoped)
        {:error, wmsg} = ReqLLM.Tool.execute(write, %{"path" => "secret.txt", "content" => "x"})
        # the notice is a read-only bind, so the write fails loudly and the
        # host file is untouched (it used to succeed into /dev/null)
        assert wmsg =~ "Read-only" or wmsg =~ "read-only"
        assert File.read!(secret) == "TOPSECRET"
      end
    end

    test "a hidden directory holds the notice, not its contents", %{skip: skip} do
      if skip do
        :ok
      else
        root = ctx_root()
        File.mkdir_p!(Path.join(root, "secret-dir"))
        File.write!(Path.join(root, "secret-dir/inside.txt"), "TOPSECRET")
        File.write!(Path.join(root, "visible.txt"), "ok")

        scoped = scope(root, hide: [Path.join(root, "secret-dir")])

        list = tool("list_dir", scoped)
        {:ok, out} = ReqLLM.Tool.execute(list, %{"path" => "."})
        # the directory is no longer empty to a listing: it carries the
        # notice, which is the whole point (an empty tmpfs was
        # indistinguishable from a missing directory)
        refute out =~ "inside.txt"

        read = tool("read_file", scoped)

        assert {:ok, content} =
                 ReqLLM.Tool.execute(read, %{"path" => "secret-dir/README.txt"})

        assert content =~ "Hidden by the harness"

        # everything else under it is gone, exactly as if absent
        {:error, msg} = ReqLLM.Tool.execute(read, %{"path" => "secret-dir/inside.txt"})
        assert msg =~ "No such file"
        refute msg =~ "TOPSECRET"
      end
    end

    test "a hidden path cannot be deleted or moved (ADR 045)", %{skip: skip} do
      if skip do
        :ok
      else
        root = ctx_root()
        secret = Path.join(root, "secret.txt")
        File.write!(secret, "TOPSECRET")

        scoped = scope(root, hide: [secret])

        # Measured under real bwrap: `rm`/`mv` on the mount point fail with
        # EBUSY (the mount cannot be detached from inside), not with EROFS
        # as a plain read-only *file* would — `tee` on the same path does
        # report EROFS. The host file is untouched either way; that is the
        # point.
        delete = tool("delete_file", scoped)
        {:error, dmsg} = ReqLLM.Tool.execute(delete, %{"path" => "secret.txt"})
        assert dmsg =~ "busy" or dmsg =~ "Read-only"
        assert File.read!(secret) == "TOPSECRET"

        move = tool("move_file", scoped)
        {:error, mmsg} = ReqLLM.Tool.execute(move, %{"from" => "secret.txt", "to" => "moved.txt"})
        assert mmsg =~ "busy" or mmsg =~ "Read-only"
        refute File.exists?(Path.join(root, "moved.txt"))
      end
    end
  end

  describe "read-only binds (ro)" do
    test "a ro path is readable and writes fail with EROFS", %{skip: skip} do
      if skip do
        :ok
      else
        root = ctx_root()
        ro_dir = Path.join(@tmp_root, "shared-ro")
        File.mkdir_p!(ro_dir)
        File.write!(Path.join(ro_dir, "data.txt"), "readable")

        scoped = scope(root, ro: [ro_dir])

        read = tool("read_file", scoped)

        assert {:ok, "readable"} =
                 ReqLLM.Tool.execute(read, %{"path" => Path.join(ro_dir, "data.txt")})

        write = tool("write_file", scoped)

        {:error, msg} =
          ReqLLM.Tool.execute(write, %{"path" => Path.join(ro_dir, "new.txt"), "content" => "x"})

        assert msg =~ "Read-only" or msg =~ "read-only"
        refute File.exists?(Path.join(ro_dir, "new.txt"))
      end
    end
  end

  describe "the root bind mode" do
    test "the scope root is writable by default and the read is confined", %{skip: skip} do
      if skip do
        :ok
      else
        root = ctx_root()
        scoped = scope(root)

        write = tool("write_file", scoped)
        assert {:ok, _} = ReqLLM.Tool.execute(write, %{"path" => "out.txt", "content" => "hello"})
        assert File.read!(Path.join(root, "out.txt")) == "hello"

        read = tool("read_file", scoped)
        assert {:ok, "hello"} = ReqLLM.Tool.execute(read, %{"path" => "out.txt"})
      end
    end

    test "with a read-only scope (root_ro) a write fails but a read works", %{skip: skip} do
      if skip do
        :ok
      else
        root = ctx_root()
        File.write!(Path.join(root, "f.txt"), "content")

        # A read-only agent's scope profile (plan agent, shell_mode: :ro):
        # the PROFILE is the boundary, not the tool list (ADR 030).
        scoped = Map.put(scope(root), :shell_mode, :ro)

        read = tool("read_file", scoped)
        assert {:ok, "content"} = ReqLLM.Tool.execute(read, %{"path" => "f.txt"})

        write = tool("write_file", scoped)
        {:error, msg} = ReqLLM.Tool.execute(write, %{"path" => "new.txt", "content" => "x"})
        assert msg =~ "Read-only" or msg =~ "read-only"
        refute File.exists?(Path.join(root, "new.txt"))
      end
    end

    test "parents: true runs its mkdir under the same profile (EROFS on root_ro)", %{skip: skip} do
      if skip do
        :ok
      else
        root = ctx_root()
        scoped = Map.put(scope(root), :shell_mode, :ro)
        write = tool("write_file", scoped)

        {:error, msg} =
          ReqLLM.Tool.execute(write, %{
            "path" => "new-dir/new.txt",
            "content" => "x",
            "parents" => true
          })

        # the confined mkdir is what failed, on the same read-only bind as
        # the write would have — one boundary, not two
        assert msg =~ "Read-only" or msg =~ "read-only"
        refute File.exists?(Path.join(root, "new-dir"))
      end
    end
  end

  describe "delete_file and move_file are confined rm/mv (ADR 045)" do
    test "a file deletes and a rename moves", %{skip: skip} do
      if skip do
        :ok
      else
        root = ctx_root()
        File.write!(Path.join(root, "a.txt"), "content")

        delete = tool("delete_file", scope(root))
        assert {:ok, _} = ReqLLM.Tool.execute(delete, %{"path" => "a.txt"})
        refute File.exists?(Path.join(root, "a.txt"))

        File.write!(Path.join(root, "b.txt"), "content")
        move = tool("move_file", scope(root))
        assert {:ok, _} = ReqLLM.Tool.execute(move, %{"from" => "b.txt", "to" => "c.txt"})
        assert File.read!(Path.join(root, "c.txt")) == "content"
      end
    end

    test "under a read-only root (root_ro) both fail with EROFS", %{skip: skip} do
      if skip do
        :ok
      else
        root = ctx_root()
        File.write!(Path.join(root, "a.txt"), "content")

        scoped = Map.put(scope(root), :shell_mode, :ro)

        delete = tool("delete_file", scoped)
        {:error, dmsg} = ReqLLM.Tool.execute(delete, %{"path" => "a.txt"})
        assert dmsg =~ "Read-only" or dmsg =~ "read-only"
        assert File.exists?(Path.join(root, "a.txt"))

        move = tool("move_file", scoped)
        {:error, mmsg} = ReqLLM.Tool.execute(move, %{"from" => "a.txt", "to" => "z.txt"})
        assert mmsg =~ "Read-only" or mmsg =~ "read-only"
        refute File.exists?(Path.join(root, "z.txt"))
      end
    end
  end

  defp ctx_root do
    root = Path.join(@tmp_root, "scope-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end
end
