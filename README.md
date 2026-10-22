# CodingAgent

An agentic coding assistant for the terminal — trustworthy, lightweight,
compilable from source.

Status: phases 1–2 complete — core agent loop (streaming, multi-turn
chat, ollama provider) plus the tool subsystem with a permission gate:
read-only tools and gated `write_file`/`edit`/`shell` (slices 2a–2e).
Next: the dogfood milestone. See [ROADMAP.md](ROADMAP.md),
[docs/source/explanation/about-tools.rst](docs/source/explanation/about-tools.rst)
and the ADR log under [docs/source/decisions/](docs/source/decisions/index.rst).

## Quick start

    # Requirements: Erlang/OTP 28, Elixir 1.20 (see ADR 008),
    # a Rust toolchain (rustc/cargo) — ex_ratatui's NIF is built from
    # source (ADR 035)
    mix deps.get
    mix tui                   # the terminal UI (the only surface)

The TUI is the product: sessions, the session picker/manager, approvals
and every verb live there (`mix tui --resume <id>`, `mix tui --store
<name|path>`). The configured model (from
`~/.config/coding-agent/config.toml`) drives every turn.

Providers may need a key: copy `.env.example` to `.env` and fill in the
variable named there (the ollama provider sends no Authorization
header).

## What can it do

Twelve tools, all confined by the session's sandbox profile (ADR 030:
the profile is the one boundary; a session refuses to start when no
confining sandbox is available):

- Read-only: `list_dir`, `read_file`, `grep`, `glob`, `question`,
  `todowrite` — plus `edit` and `write_file` (allow-by-policy; every
  change reviewable as a git diff). A repo/user policy file can still
  turn them back to ask/deny per path.
- State-changing: `shell`, `git`, `webfetch`, `task` (delegation).

`shell`/`git` are allow-by-default inside the profile — a stated
escalation (`network`, `change_vcs`) still asks, and every call can be
made ask/deny by policy. `shell` runs through `/bin/sh` with
model-supplied `timeout_secs` (default 300 s, hard cap 1800 s).
`grep`/`glob` use `rg`/`fd` (required; there is no unconfined fallback).

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