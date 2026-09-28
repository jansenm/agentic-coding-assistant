defmodule CodingAgent.Core.Sandbox.FileToolsConfinementTest do
  @moduledoc """
  The LIVE confinement semantics of the native file tools under real
  bwrap (ADR 030): `read_file`, `write_file`, `edit` and `list_dir` are
  confined processes, so the PROFILE decides reach.

  - a `hide`d path reads as its empty image and cannot be written;
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
    test "a hidden file reads as empty and cannot be written", %{skip: skip} do
      if skip do
        :ok
      else
        root = ctx_root()
        secret = Path.join(root, "secret.txt")
        File.write!(secret, "TOPSECRET")

        scoped = scope(root, hide: [secret])

        read = tool("read_file", scoped)
        assert {:ok, content} = ReqLLM.Tool.execute(read, %{"path" => "secret.txt"})
        # /dev/null binds over the file: reads succeed with empty content
        assert content == ""

        write = tool("write_file", scoped)
        assert {:ok, _} = ReqLLM.Tool.execute(write, %{"path" => "secret.txt", "content" => "x"})
        # the write went to /dev/null; the host file is untouched
        assert File.read!(secret) == "TOPSECRET"
      end
    end

    test "a hidden directory does not leak into list_dir", %{skip: skip} do
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
        # the tmpfs is empty; the inner file is not there
        refute out =~ "inside.txt"

        # the hidden directory is an empty tmpfs: the inner path does not
        # exist at all (a hidden FILE reads as empty instead)
        read = tool("read_file", scoped)
        {:error, msg} = ReqLLM.Tool.execute(read, %{"path" => "secret-dir/inside.txt"})
        assert msg =~ "No such file"
        refute msg =~ "TOPSECRET"
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
  end

  defp ctx_root do
    root = Path.join(@tmp_root, "scope-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end
end
