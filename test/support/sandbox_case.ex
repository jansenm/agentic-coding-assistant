defmodule CodingAgent.SandboxCase do
  @moduledoc """
  Test helper for tests that switch the global `:sandbox` application env.

  The env is process-global, so every test that writes it must restore the
  previous value — otherwise a test that pins another sandbox leaks into
  the rest of the suite (and, under ADR 030, makes session starts refuse).
  `async: false` is the caller's responsibility.

  Two uses:

      setup do
        put_sandbox(CodingAgent.TestSandbox.Stub)
        :ok
      end

  or, when the original value must be read first:

      setup do
        original = put_sandbox!(my_module)
        ...
      end
  """

  @doc """
  Sets the sandbox implementation for the current test and restores the
  previous value on exit. Call from `setup` (or a test body).
  """
  @spec put_sandbox(module() | nil) :: :ok
  def put_sandbox(module) do
    original = Application.get_env(:coding_agent, :sandbox)
    Application.put_env(:coding_agent, :sandbox, module)

    ExUnit.Callbacks.on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:coding_agent, :sandbox)
      else
        Application.put_env(:coding_agent, :sandbox, original)
      end
    end)

    :ok
  end

  @doc """
  Like `put_sandbox/1`, but returns the previously configured module so a
  test can assert against it.
  """
  @spec put_sandbox!(module() | nil) :: module() | nil
  def put_sandbox!(module) do
    original = Application.get_env(:coding_agent, :sandbox)
    :ok = put_sandbox(module)
    original
  end
end
