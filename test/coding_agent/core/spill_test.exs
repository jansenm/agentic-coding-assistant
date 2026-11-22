# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.SpillTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Spill

  @scratch System.tmp_dir!() |> Path.join("spill-test-#{System.unique_integer([:positive])}")

  # The suite's sandbox double is confining but does not bind the scratch
  # over /tmp, so `Sandbox.visible_path/2` reports the host path. That is
  # the shape these tests pin: the announced path is the sandbox's ANSWER,
  # not a `/tmp` prefix this module glued on (N99 — with TMPDIR set, the
  # hardcoded one named a file beside the real one).
  setup do
    File.rm_rf!(@scratch)
    on_exit(fn -> File.rm_rf!(@scratch) end)

    %{profile: %{root: System.tmp_dir!(), scratch: @scratch}}
  end

  test "spills into <scratch>/spill and reports the path the sandbox sees", %{profile: p} do
    assert {:ok, path} = Spill.spill("hello world", p, "shell")

    # the sandbox double is a pass-through, so the announced path IS the
    # host path; the file must exist there, not "beside" it
    assert path == Path.join(Spill.dir(@scratch), Path.basename(path))
    assert File.read!(path) == "hello world"
  end

  test "no session scratch is :no_scratch (the caller keeps its plain truncation)" do
    assert Spill.spill("x", %{root: "/repo"}, "grep") == :no_scratch
    assert Spill.spill("x", %{root: "/repo", scratch: nil}, "grep") == :no_scratch
    assert Spill.spill("x", %{root: "/repo", scratch: ""}, "grep") == :no_scratch
    assert Spill.open_writer(%{root: "/repo"}, "grep") == :no_scratch
  end

  test "dir/1 is the spill subdirectory" do
    assert Spill.dir(@scratch) == Path.join(@scratch, "spill")
  end

  test "a spill larger than the cap is itself head+tail truncated, with a marker", %{profile: p} do
    big = String.duplicate("x", Spill.max_bytes() + 1024)
    assert {:ok, path} = Spill.spill(big, p, "shell")

    data = File.read!(path)

    assert data =~ "spill truncated"
    # head + marker + tail, so the file does not keep the whole input
    assert byte_size(data) <= Spill.max_bytes() + 200
  end

  describe "streaming writer (review N35)" do
    test "keeps head AND tail, the same shape as spill/3", %{profile: p} do
      # 40 x 1 MiB, each with a recognizable boundary, so head and tail
      # can be told apart.
      {:ok, w} = Spill.open_writer(p, "shell")

      w =
        Enum.reduce(1..40, w, fn i, w ->
          {_, w} =
            Spill.write(
              w,
              "CHUNK#{i}-START" <> String.duplicate("x", 1_048_576) <> "CHUNK#{i}-END"
            )

          w
        end)

      {:ok, w} = Spill.finish(w)
      data = File.read!(Spill.host_path(w))

      # the marker names the same things `spill/3` does (review N49):
      # the TOTAL bytes, not just the cap
      assert data =~
               ~r/\[\.\.\. spill truncated: \d+ bytes total; showing first \d+ and last \d+ \.\.\.\]/

      # head: the first chunk; tail: the last chunk (the useful part of a
      # crashed run's log). The first version dropped the tail.
      assert data =~ "CHUNK1-START"
      assert data =~ "CHUNK40-END"
      assert byte_size(data) <= Spill.max_bytes() + 1024

      # the finished writer names the same file it wrote
      assert w.path == Spill.host_path(w)
    end

    test "under the cap the file is the whole output, no marker", %{profile: p} do
      {:ok, w} = Spill.open_writer(p, "grep")
      {:ok, w} = Spill.write(w, "alpha ")
      {:ok, w} = Spill.write(w, "beta")
      {:ok, w} = Spill.finish(w)

      assert File.read!(Spill.host_path(w)) == "alpha beta"
    end
  end
end
