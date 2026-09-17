defmodule CodingAgent.Core.SandboxTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Sandbox
  alias CodingAgent.Core.Sandbox.None

  defmodule SomeStub do
    @behaviour CodingAgent.Core.Sandbox

    @impl true
    def id, do: :some_stub

    @impl true
    def available?, do: true

    @impl true
    def confines?, do: true

    @impl true
    def wrap(command, profile), do: {:ok, "/stub", ["-c", command, profile]}
  end

  setup do
    on_exit(fn -> Application.delete_env(:coding_agent, :sandbox) end)
    :ok
  end

  describe "selection" do
    test "defaults to Sandbox.None" do
      Application.delete_env(:coding_agent, :sandbox)
      assert Sandbox.impl() == None
    end

    test "honours the :sandbox application env" do
      Application.put_env(:coding_agent, :sandbox, SomeStub)
      assert Sandbox.impl() == SomeStub
    end

    test "wrap/2 delegates to the configured implementation" do
      Application.put_env(:coding_agent, :sandbox, SomeStub)

      assert {:ok, "/stub", ["-c", "echo hi", %{root: "/repo"}]} =
               Sandbox.wrap("echo hi", %{root: "/repo"})
    end
  end

  describe "Sandbox.None" do
    test "is always available" do
      assert None.available?()
    end

    test "does not confine" do
      refute None.confines?()
      Application.delete_env(:coding_agent, :sandbox)
      refute Sandbox.confines?()
    end

    test "wraps the command as /bin/sh -c, ignoring the profile" do
      assert {:ok, "/bin/sh", ["-c", "rm -rf /"]} =
               None.wrap("rm -rf /", %{root: "/repo", network: true, git_write: true})
    end

    test "id is :none" do
      assert None.id() == :none
    end
  end

  describe "confines?/0" do
    test "is true for a confining implementation that is available" do
      Application.put_env(:coding_agent, :sandbox, SomeStub)
      assert Sandbox.confines?()
    end

    test "is false when the confining implementation is unavailable" do
      Application.put_env(:coding_agent, :sandbox, UnavailableStub)
      refute Sandbox.confines?()
    end
  end

  defmodule UnavailableStub do
    @behaviour CodingAgent.Core.Sandbox

    @impl true
    def id, do: :unavailable_stub

    @impl true
    def available?, do: false

    @impl true
    def confines?, do: true

    @impl true
    def wrap(_command, _profile), do: {:error, :unavailable}
  end
end
