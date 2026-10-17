defmodule CodingAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :coding_agent,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      test_coverage: test_coverage()
    ]
  end

  # `mix test --cover` gate. The live-LLM seams (Request/ProviderHealth)
  # and the CLI entry points (Mix.Tasks.*) run only against a provider or
  # a tty and stay near 0% by design; 75% guards against broad regression
  # without pretending those modules are unit-testable.
  defp test_coverage do
    [summary: [threshold: 75]]
  end

  # Test-only support modules (test/support) compile into the test env:
  # shared synchronization helpers that keep the suite sleep-free.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {CodingAgent.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req_llm, "~> 1.21"},
      {:dotenvy, "~> 1.1"},
      {:ex_ratatui, "~> 0.13"},
      # ex_ratatui's NIF is built from source, not the precompiled
      # artifact: the shipped v0.13.1 binary crashes (SIGSEGV through a
      # null pointer in the render NIF, 4x — see ADR 035). Forcing a
      # source build needs `:rustler` declared here explicitly; it is an
      # optional dep of ex_ratatui and optional deps are not fetched
      # transitively.
      {:rustler, "~> 0.38"},
      # YAML frontmatter for agent definitions (ADR 017/019). Pure Erlang,
      # no NIF; used directly (not via yaml_elixir, which only wraps it).
      {:yamerl, "~> 0.10"},
      # Session storage engine (ADR 020/023). SQLite has no pure-BEAM
      # driver; this is the one core-path NIF, isolated behind
      # Core.Session.Store. We use its raw `Exqlite.Sqlite3` API (not
      # ecto_sqlite3) — ADR 020 chose SQL directly, no Ecto.
      {:exqlite, "~> 0.40"}
    ]
  end
end
