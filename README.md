<!--
SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>

SPDX-License-Identifier: MPL-2.0
-->

# CodingAgent

An agentic coding assistant for the terminal — trustworthy, lightweight,
compilable from source.

> **Status: alpha.** The core is in place and the project is developing
> itself with it (the dogfood milestone is met), but there is no release,
> no compatibility promise and no Hex package. The internal app name is
> `coding_agent`; the display name is still deferred ([ADR 009](docs/source/decisions/009-naming.rst)).
> Phases and open work: [ROADMAP.md](ROADMAP.md) and [TODO.md](TODO.md).

## What it is

A single TUI session that talks to an LLM, streams its reasoning and
turns, and calls tools to read, search and change your files. The design
choices that shape everything else:

- **The sandbox profile is the boundary.** Every tool runs as a confined
  process (bubblewrap). A session refuses to start when no confining
  sandbox is available — there is no unconfined fallback
  ([ADR 030](docs/source/decisions/030-one-boundary.rst)).
- **State-changing calls go through a permission gate** and every file
  change is reviewable as a git diff; git is the undo mechanism.
- **The model is a parameter.** Any provider `req_llm` supports, plus
  OpenAI-compatible and ollama endpoints. There is no default model: you
  set one, and the TUI refuses to start without it.
- **Everything is inspectable.** Docs are the design record (ADRs), the
  tool surface is a registry in one module, and the session store is a
  plain SQLite file you can query.

## Requirements

- **Erlang/OTP 28** and **Elixir ~> 1.20** ([ADR 008](docs/source/decisions/008-scaffold.rst))
- **A Rust toolchain** (`rustc`/`cargo`) — the TUI backend's NIF is built
  from source ([ADR 035](docs/source/decisions/035-ex-ratatui-source-build.rst))
- **bubblewrap** (`bwrap`) with unprivileged user namespaces enabled;
  the binary is probed functionally, not by version string
- **`rg`** (ripgrep) and **`fd`** — the search tools delegate to them
  ([ADR 016](docs/source/decisions/016-native-search-delegation.rst))
- **git**, and a Linux host (the sandbox implementation is Linux-only)

## Quick start

```sh
mix deps.get
mix tui
```

The TUI is the only surface. Sessions, the picker, approvals and every
verb live there:

```sh
mix tui                       # new session in the current directory
mix tui --resume <session-id> # resume a persisted session
mix tui --store <name|path>   # pick which session store to use
mix tui "explain this repo"   # start with a first prompt
```

## Configuration

Three layers, later ones win:

1. `priv/coding-agent/config.toml` — shipped defaults, do not edit
2. `~/.config/coding-agent/config.toml` — your user config
3. `.coding-agent/config.toml` — per-project config (committed with the project)

The model is set per run with `AGENT_MODEL` or with `model =` in config,
e.g. `model = "ollama:qwen3-coder"`; nothing is configured out of the box,
and the TUI names the missing piece when it refuses to start. Credentials
are read from the environment or from
`~/.local/share/coding-agent/auth.toml`; copy `.env.example` to `.env`
to set a provider key. `auth.toml` is global only — a project file can
never carry a secret.

Per-project permissions live in `.coding-agent/permissions.toml`; see the
[configuration reference](docs/source/reference/index.rst).

## Tools

Sixteen tools, all confined by the session's sandbox profile:

- **Read-only:** `list_dir`, `read_file`, `grep`, `glob`, `question`,
  `todowrite`, `compact`
- **State-changing, behind the gate:** `write_file`, `edit`,
  `delete_file`, `move_file`, `move_region`, `shell`, `git`, `webfetch`
- **Delegation:** `task` (a primary session may hand work to a subagent)

`shell` and `git` are allow-by-default inside the profile; a stated
escalation (`network`, `change_vcs`) still asks, and policy can turn any
tool to ask/deny by path. `shell` runs through `/bin/sh` with a
model-supplied timeout (default 300 s, hard cap 1800 s).

## Documentation

The documentation is a Sphinx site and the project's design record:

- [docs/source/explanation/](docs/source/explanation/index.rst) — architecture and the stack
- [docs/source/reference/](docs/source/reference/index.rst) — config keys, environment, tools
- [docs/source/decisions/](docs/source/decisions/index.rst) — the ADR log
- [AGENTS.md](AGENTS.md) — the rules this repository is developed under
- [ROADMAP.md](ROADMAP.md) / [TODO.md](TODO.md) — where it is going, what is next

## Development

```sh
mix test                      # the suite (the measure of a change)
mix format --check-formatted
make -C docs html             # docs; `make -C docs livehtml` for autobuild
reuse lint                    # licensing headers
```

The suite starts real processes and real sandboxes; it expects the
requirements above. It is the contract: a change is done when `mix test`
is green without warnings that a test did not declare.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: open an issue first for
anything larger than a fix, keep a change's test with the change, and
expect review to be about the design record (an ADR) as much as about
the code.

## License

[MPL-2.0](LICENSE). Third-party material redistributed in this tree is
listed in [THIRD_PARTY.md](THIRD_PARTY.md), with its own licenses kept in
[`LICENSES/`](LICENSES/). Every file carries its licensing as SPDX tags
(or in [REUSE.toml](REUSE.toml) where a header cannot be written);
`reuse lint` verifies it.
