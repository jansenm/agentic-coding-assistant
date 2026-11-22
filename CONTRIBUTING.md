<!--
SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>

SPDX-License-Identifier: MPL-2.0
-->

# Contributing

Thanks for looking. This project is in **alpha**: the shape still moves,
and a change that looks obvious may still be waiting for a design
decision. That is the main thing to know before you write code.

## Before you start

- **Open an issue first** for anything that is not a small fix. The
  interesting part of this repository is *why* it is built the way it is;
  a change that ignores an ADR will be asked to argue with it. Findings and
  ideas are tracked as issues on the project, not in a file: one issue per
  finding, the `N…`/`P…`/`I…` number in the title is the ID.
- **Read [AGENTS.md](AGENTS.md).** It is the rulebook the code is written
  under (design principles first, no duplication, separation of concerns,
  no backwards compatibility while unreleased). It applies to humans too.
- **Build it locally** using the requirements in the [README](README.md).
  You need bwrap, `rg`, `fd`, a Rust toolchain and OTP 28.

## The loop

```sh
mix test                      # the measure of a change
mix format --check-formatted
reuse lint                    # every file carries SPDX tags
make -C docs html             # if you touched docs/
```

A change is done when `mix test` is green **with no undeclared
warnings**. If your test triggers a warning on purpose, capture it and
assert it (`capture_log/1` plus `assert log =~ "…"`); do not mute the
suite. Tests start real processes and real sandboxes — that is
deliberate, and a test may not depend on the developer's machine.

## Commits

`type(scope): what changed, and the why when it is not obvious` — one
logical change per commit, with the reasoning in the message body if the
subject cannot carry it. Types seen here: `feat`, `fix`, `refactor`,
`test`, `docs`, `perf`, `chore`. Reference the ADR or finding a change
settles (`(ADR 030)`, `(N122)`) when one exists.

## Licensing

The project is [MPL-2.0](LICENSE), inbound = outbound: by contributing
you agree that your contribution is licensed under the same terms. There
is no CLA.

New files need the two-line SPDX header (`SPDX-FileCopyrightText`,
`SPDX-License-Identifier`). Do not add one where it would change
behaviour — agent definitions, prompt text and generated files are
covered in [REUSE.toml](REUSE.toml) instead. `reuse lint` tells you what
is missing.

Third-party code or text must be recorded in
[THIRD_PARTY.md](THIRD_PARTY.md) with its license text in `LICENSES/`.

## Security

Please do not open a public issue for a sandbox escape, a permission-gate
bypass or a credential leak. Mail <ferroclass@michael-jansen.biz> instead.
Everything else — including "this tool can do X and I think it should not"
— is a normal issue.
