defmodule CodingAgent.Core.SpillTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Spill

  @scratch System.tmp_dir!() |> Path.join("spill-test-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@scratch)
    on_exit(fn -> File.rm_rf!(@scratch) end)
    :ok
  end

  test "spills into <scratch>/spill and reports the /tmp path the sandbox sees" do
    assert {:ok, path} = Spill.spill("hello world", @scratch, "shell")
    assert String.starts_with?(path, "/tmp/spill/shell-")

    host = Path.join(@scratch, String.replace_prefix(path, "/tmp/", ""))
    assert File.read!(host) == "hello world"
  end

  test "no session scratch is :no_scratch (the caller keeps its plain truncation)" do
    assert Spill.spill("x", nil, "grep") == :no_scratch
    assert Spill.spill("x", "", "grep") == :no_scratch
  end

  test "dir/1 is the spill subdirectory; sandbox_path/2 rewrites the scratch prefix" do
    assert Spill.dir(@scratch) == Path.join(@scratch, "spill")

    host = Path.join([@scratch, "spill", "webfetch-7"])
    assert Spill.sandbox_path(host, @scratch) == "/tmp/spill/webfetch-7"
  end

  test "a spill larger than the cap is itself head+tail truncated, with a marker" do
    big = String.duplicate("x", Spill.max_bytes() + 1024)
    assert {:ok, path} = Spill.spill(big, @scratch, "shell")

    host = Path.join(@scratch, String.replace_prefix(path, "/tmp/", ""))
    data = File.read!(host)

    assert data =~ "spill truncated"
    # head + marker + tail, so the file does not keep the whole input
    assert byte_size(data) <= Spill.max_bytes() + 200
  end
end
