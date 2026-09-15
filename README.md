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

    # Requirements: Erlang/OTP 28, Elixir 1.20 (see ADR 008)
    mix deps.get
    mix agent "Say hello"
    mix agent --chat          # multi-turn session

The configured default model (`ollama:glm-5.3-flash:cloud`, see
config/config.exs) needs **no API key** — the ollama provider sends no
Authorization header. Other providers do: copy `.env.example` to `.env`
and fill in the key variable named there.

## What can it do

Eight tools, all scope-contained — every path is resolved physically
(symlinks followed) and must stay inside the session scope
(details: about-tools.rst):

- Read-only, run without approval: `list_dir`, `read_file`, `grep`,
  `glob` — plus `edit` and `write_file` (allow-by-policy 2026-09-15:
  contained paths, every change reviewable as a git diff; see the
  ADR 010 amendment). A repo/user policy file can still turn them
  back to ask/deny per path.
- State-changing, paused for y/n approval in the terminal (approve, edit
  the parameters, or reject): `shell`, `webfetch`

`shell` runs through `/bin/sh` with model-supplied `timeout_secs`
(default 300 s, hard cap 1800 s) and is asked on *every* call — no
allow-list in v1.

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