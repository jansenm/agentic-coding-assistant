defmodule CodingAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :coding_agent,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

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
      {:ex_ratatui, "~> 0.13"}
    ]
  end
end
