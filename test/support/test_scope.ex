defmodule CodingAgent.TestScope do
  @moduledoc """
  Scope roots for tests that start a REAL session (not `test_mode`).

  Such a session resolves its compaction window config → catalog →
  fallback. The test models are unknown to the catalog by construction, so
  the fallback fires and the session logs once:

      context window for ollama:test-model is unknown to the model
      catalog; assuming 500k tokens …

  That warning is for the OWNER of a live session whose model may be
  mis-sized. A test that needs real ports (transport retries, a crashing
  worker, a catalog flip) does not mean to trigger it, and an unaccounted
  warning line is noise the next reader has to attribute. `declare_window!/1`
  writes a project config that DECLARES the window: the same 500k the
  fallback would have guessed, but as a decision (`:configured`), so the
  session has nothing to warn about.

  Tests that ARE about the fallback — the catalog tests that assert
  `:loading`/`:fallback` and the one warning — must not use this; they
  capture the log and assert it (`capture_log/1`), which is the rule for
  every warning a test triggers on purpose.
  """

  @window 500_000

  @doc """
  Writes `.coding-agent/config.toml` under `root` declaring the window
  (500k by default — the fallback's own guess, so numbers do not move).
  Returns `root` for use in a pipeline.
  """
  @spec declare_window!(Path.t(), pos_integer()) :: Path.t()
  def declare_window!(root, window \\ @window) do
    dir = Path.join(root, ".coding-agent")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.toml"), "context_window = #{window}\n")
    root
  end

  @doc "The window `declare_window!/2` writes when none is given."
  @spec window() :: pos_integer()
  def window, do: @window
end
