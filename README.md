# CodingAgent

An agentic coding assistant for the terminal — trustworthy, lightweight,
compilable from source.

Status: phase 1 (core agent loop). See [ROADMAP.md](ROADMAP.md) for the
plan and [docs/](docs/source/index.rst) for architecture and the ADR log.

## Quick start

    # Requirements: Erlang/OTP 28, Elixir 1.20 (see ADR 008)
    mix deps.get
    cp .env.example .env   # add your provider API key
    mix agent "Say hello"

## Development

    mix test
    make -C docs livehtml SPHINXAUTOBUILD=docs/.venv/bin/sphinx-autobuild

> This README is a stub; the real one arrives with the display name (ADR 009).

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `coding_agent` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:coding_agent, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/coding_agent>.

