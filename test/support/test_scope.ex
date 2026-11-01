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

  ## The root outlives the test

  The other half is lifetime: a session started here lives in the app's
  session supervisor, not in the test process, so it can outlive the test
  that started it. Deleting its scope root makes a later port's
  `{:cd, root}` fail and `erl_child_setup` print "spawn: Could not cd to …"
  on the VM's stderr (review N122, form 1) — noise no test can assert.
  `root!/1` therefore creates a run-scoped root and never deletes it; the
  run TMPDIR (`test_helper.exs`) owns the tree.
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

  @doc """
  A scope root that lives until the RUN ends.

  A test that starts a REAL session must not delete its root: the session
  outlives the test (it lives in the app's session supervisor), and a port
  spawned afterwards with `{:cd, root}` makes `erl_child_setup` print
  "spawn: Could not cd to …" straight to the VM's stderr, where no port and
  no `capture_log` can see it (review N122, form 1). The run-scoped TMPDIR
  (`test_helper.exs`) owns the tree and removes it at VM exit.
  """
  @spec root!(String.t()) :: Path.t()
  def root!(name) do
    root = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  @doc "The window `declare_window!/2` writes when none is given."
  @spec window() :: pos_integer()
  def window, do: @window
end
