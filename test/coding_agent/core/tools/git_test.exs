defmodule CodingAgent.Core.Tools.GitTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.Git

  @tmp_root System.tmp_dir!() |> Path.join("agent-git-#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    Application.put_env(:coding_agent, :sandbox, CodingAgent.Core.Sandbox.None)
    {:ok, root: @tmp_root}
  end

  describe "registration and schema" do
    test "git is in the gated tool list", %{root: root} do
      names = Tools.gated(%{root: root}) |> Enum.map(& &1.name)
      assert "git" in names
    end

    test "the tool builds with a valid schema", %{root: root} do
      assert %ReqLLM.Tool{name: "git"} = Git.tool(%{root: root})
    end
  end

  describe "argv/1 (pure)" do
    test "accepts a non-empty string list" do
      assert {:ok, ["status"]} = Git.argv(%{"args" => ["status"]})
      assert {:ok, ["commit", "-am", "x"]} = Git.argv(%{args: ["commit", "-am", "x"]})
    end

    test "rejects empty, non-list and non-string entries" do
      assert {:error, _} = Git.argv(%{"args" => []})
      assert {:error, _} = Git.argv(%{"args" => "status"})
      assert {:error, _} = Git.argv(%{"args" => ["ok", 42]})
      assert {:error, _} = Git.argv(%{})
      assert {:error, _} = Git.argv("nope")
    end
  end

  describe "profile/1" do
    test "always grants git_write and keeps the network off", %{root: root} do
      profile = Git.profile(%{root: root, mounts: %{rw: ["/rw"], ro: [], hide: []}})

      assert profile.git_write == true
      assert profile.network == false
      assert profile.rw == ["/rw"]
    end

    test "tolerates a scope without mounts", %{root: root} do
      profile = Git.profile(%{root: root})
      assert profile.rw == []
      assert profile.ro == []
      assert profile.hide == []
    end
  end

  describe "effective_timeout/1" do
    test "defaults, clamps and rejects" do
      assert {:ok, 120} = Git.effective_timeout(%{})
      assert {:ok, 30} = Git.effective_timeout(%{"timeout_secs" => 30})
      assert {:ok, 1} = Git.effective_timeout(%{"timeout_secs" => 0})
      assert {:error, msg} = Git.effective_timeout(%{"timeout_secs" => 99999})
      assert msg =~ "hard cap"
      assert {:ok, 120} = Git.effective_timeout("nope")
    end
  end

  describe "execution (unconfined, direct)" do
    test "runs a real git command and reports output", %{root: root} do
      git!(root, ~w(init -q -b main))
      tool = Git.tool(%{root: root})

      assert {:ok, out} = ReqLLM.Tool.execute(tool, %{"args" => ["status"]})
      assert out =~ "exit 0"
    end

    test "arguments are passed as argv, not through a shell (no injection)", %{root: root} do
      git!(root, ~w(init -q -b main))
      marker = Path.join(root, "injected-#{System.unique_integer()}")
      tool = Git.tool(%{root: root})

      # If this were joined into a shell string, `; touch marker` would
      # execute. As argv it is one (invalid) ref argument to git.
      assert {:ok, out} =
               ReqLLM.Tool.execute(tool, %{
                 "args" => ["log", "--oneline", "; touch #{marker}"]
               })

      refute File.exists?(marker)
      assert out =~ "exit 128" or out =~ "fatal"
    end

    test "rejects a bad args payload with an error", %{root: root} do
      tool = Git.tool(%{root: root})
      assert {:error, msg} = ReqLLM.Tool.execute(tool, %{"args" => []})
      assert msg =~ "non-empty list"
    end
  end

  defp git!(root, args) do
    {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
  end
end
