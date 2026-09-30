defmodule CodingAgent.Core.ExecTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.Sandbox

  @tmp_root System.tmp_dir!() |> Path.join("agent-exec-#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    %{profile: %{root: @tmp_root}}
  end

  defp tmp(name), do: Path.join(@tmp_root, name)

  describe "run/5 stdin (ADR 030)" do
    test "feeds the payload to the child's standard input", %{profile: profile} do
      file = tmp("via-tee.txt")

      assert {:ok, output, 0} =
               Exec.run({:exec, "tee", [file]}, @tmp_root, 10, profile, stdin: "hello\n")

      # tee echoes stdin to stdout AND writes the file
      assert output =~ "hello"
      assert File.read!(file) == "hello\n"
    end

    test "is byte-exact, including multibyte and empty payloads", %{profile: profile} do
      file = tmp("bytes.txt")
      content = String.duplicate("ü✓ line\n", 500)

      assert {:ok, _, 0} =
               Exec.run({:exec, "tee", [file]}, @tmp_root, 10, profile, stdin: content)

      assert File.read!(file) == content

      empty = tmp("empty.txt")
      assert {:ok, _, 0} = Exec.run({:exec, "tee", [empty]}, @tmp_root, 10, profile, stdin: "")
      assert File.read!(empty) == ""
    end

    test "the writer sees EOF: the child terminates without a timeout", %{profile: profile} do
      # `cat` with no path reads stdin until EOF; without the pipe-close
      # trick it would hang until the deadline.
      assert {:ok, output, 0} =
               Exec.run({:exec, "cat", []}, @tmp_root, 10, profile, stdin: "drained\n")

      assert output == "drained\n"
    end

    test "works through the shell spec form too", %{profile: profile} do
      file = tmp("shell-stdin.txt")

      assert {:ok, _, 0} =
               Exec.run({:shell, "cat > #{file}"}, @tmp_root, 10, profile, stdin: "via shell\n")

      assert File.read!(file) == "via shell\n"
    end

    test "a payload larger than one port message arrives whole", %{profile: profile} do
      file = tmp("large.txt")
      content = :crypto.strong_rand_bytes(300_000)

      assert {:ok, _, 0} =
               Exec.run({:exec, "tee", [file]}, @tmp_root, 30, profile, stdin: content)

      assert File.read!(file) == content
    end
  end

  describe "run/5 env" do
    test "overrides are visible to the child", %{profile: profile} do
      assert {:ok, output, 0} =
               Exec.run({:shell, "printf '%s' \"$CA_TEST_VAR\""}, @tmp_root, 10, profile,
                 env: [{"CA_TEST_VAR", "from-env"}]
               )

      assert output == "from-env"
    end

    test "an override wins over the inherited value", %{profile: profile} do
      System.put_env("CA_TEST_INHERITED", "parent")
      on_exit(fn -> System.delete_env("CA_TEST_INHERITED") end)

      assert {:ok, output, 0} =
               Exec.run({:shell, "printf '%s' \"$CA_TEST_INHERITED\""}, @tmp_root, 10, profile,
                 env: [{"CA_TEST_INHERITED", "child"}]
               )

      assert output == "child"
    end

    test "the git editor neutralization shape works (review F7)", %{profile: profile} do
      assert {:ok, output, 0} =
               Exec.run(
                 {:shell, "printf '%s %s' \"$GIT_EDITOR\" \"$GIT_PAGER\""},
                 @tmp_root,
                 10,
                 profile,
                 env: [{"GIT_EDITOR", "true"}, {"GIT_PAGER", "cat"}]
               )

      assert output == "true cat"
    end
  end

  describe "run/5 truncate option (review F2/F5)" do
    test "default keeps head+tail with a marker", %{profile: profile} do
      # 300 KiB > 256 KiB: the default truncates
      cmd = "yes xx | head -c 300000"
      assert {:ok, out, 0} = Exec.run({:shell, cmd}, @tmp_root, 10, profile)
      assert out =~ "output truncated"
    end

    test "truncate: false returns the raw bytes, no marker", %{profile: profile} do
      cmd = "yes xx | head -c 300000"
      assert {:ok, out, 0} = Exec.run({:shell, cmd}, @tmp_root, 10, profile, truncate: false)
      refute out =~ "output truncated"
      # > the 256 KiB cap, so the raw path really was not cut
      assert byte_size(out) > 256 * 1024
    end

    test "with a session scratch the overflow spills and the marker names it (ADR 038)" do
      scratch = Path.join(@tmp_root, "scratch")
      File.mkdir_p!(scratch)
      profile = %{root: @tmp_root, scratch: scratch}

      cmd = "yes xx | head -c 300000"
      assert {:ok, out, 0} = Exec.run({:shell, cmd}, @tmp_root, 10, profile, label: "shell")

      assert out =~ "output truncated"
      assert out =~ "full output at /tmp/spill/shell-"

      # the host file really holds the FULL output
      host = Path.wildcard(Path.join(scratch, "spill/shell-*")) |> List.first()
      assert host != nil
      assert byte_size(File.read!(host)) > 256 * 1024
    end
  end

  describe "cancellation (esc kills a running command)" do
    test "a stop request kills a silent command well before its deadline", %{profile: profile} do
      id = "exec-stop-#{System.unique_integer([:positive])}"
      profile = Map.put(profile, :session_id, id)
      started = System.monotonic_time(:millisecond)

      task =
        Task.async(fn ->
          # 60s deadline; the process prints nothing, so only the stop
          # tick can end it.
          Exec.run({:shell, "echo started; sleep 60"}, @tmp_root, 60, profile)
        end)

      # let the port open, then request the stop
      Process.sleep(100)
      CodingAgent.Core.Interrupt.request(id)

      assert {:stopped, out} = Task.await(task, 5_000)
      assert out =~ "started"
      assert System.monotonic_time(:millisecond) - started < 5_000

      CodingAgent.Core.Interrupt.clear(id)
    end

    test "without a session id the command keeps its own deadline", %{profile: profile} do
      # the bare-scope profile has no :session_id; even a set flag keyed
      # by nothing must not stop it (there is no id to look up)
      assert {:timeout, _} =
               Exec.run({:shell, "sleep 60"}, @tmp_root, 1, profile)
    end
  end

  describe "stdin_command/2 (shared EOF spelling)" do
    test "wraps a shell spec in a head -c pipeline" do
      assert {:ok, "/bin/sh", ["-c", command]} =
               Sandbox.stdin_command(7, {:shell, "tee out.txt"})

      assert command =~ "head -c 7"
      assert command =~ "tee out.txt"
    end

    test "keeps exec argv as positional parameters (no re-parsing)" do
      assert {:ok, "/bin/sh", ["-c", command, "sh", exe, "a b", "; rm -rf /"]} =
               Sandbox.stdin_command(3, {:exec, "sh", ["a b", "; rm -rf /"]})

      assert command =~ "head -c 3"
      assert command =~ ~s(exec "$@")
      assert Path.type(exe) == :absolute
    end
  end
end
