.. SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
..
.. SPDX-License-Identifier: MPL-2.0

:orphan:

One binary: a Burrito release, and the entry point it forces
============================================================

.. adr::
   :id: 048
   :status: Accepted
   :date: 2026-11-22
   :tags: distribution, packaging, releases, cli

Context
-------

The README asks for OTP 28, Elixir ~> 1.20, a Rust toolchain, bubblewrap,
``rg`` and ``fd`` before the first run. That is the price of *building* the
harness, and it is the wrong price for handing it to someone who only wants
to use it.

Two things made a single-file binary the obvious next step. The repository is
public and the tool is dogfooding itself, so "clone and build" is now the only
distribution path it has; and the TUI is the whole product, so there is no
server to deploy instead.

The TUI is currently started by ``Mix.Tasks.Tui.run/1`` (``mix tui``). A
release has no Mix and no tasks: it boots through
``CodingAgent.Application.start/2``, which today only starts the supervision
tree. Whatever packages the release therefore has to move the entry point, or
the binary starts and does nothing.

Burrito (1.5.0, November 2025) wraps a Mix release and its ERTS into one
self-extracting executable. It is the successor to Bakeware, which is
archived; **Burrito itself is archived on 2026-11-30**, eight days after this
decision.

Decision
--------

Ship a Burrito-wrapped release, Linux x86_64 only, with the entry point shared
by both surfaces:

- ``{:burrito, "~> 1.5.0", runtime: false}`` and one release in ``mix.exs``:
  ``steps: [:assemble, &Burrito.wrap/1]``, target ``linux`` with
  ``os: :linux, cpu: :x86_64``, ``skip_nifs: true`` and the ERTS this build
  is running under as ``custom_erts`` (both are explained below).
- The reusable body of the ``mix tui`` task moves to ``CodingAgent.CLI``
  (``run/2``, ``await_tui/3``, the terminal reset, the log handler, the store
  selection and the model check). ``Mix.Tasks.Tui`` becomes a thin adapter.
- ``config/runtime.exs`` sets ``run_cli: true`` for ``:prod`` only, and
  ``Application.start/2`` starts ``CodingAgent.CLI`` when it is set. A release
  is ``:prod``; a checkout is not, so ``mix tui`` and ``mix test`` keep
  starting exactly one TUI.
- The binary takes its arguments from ``:init.get_plain_arguments/0`` — what
  Burrito's wrapper passes — so ``--resume``, ``--store``, ``--agent`` and the
  initial prompt work as they do under ``mix tui``.

What the binary does **not** carry: ``bwrap`` (with user namespaces), ``rg``,
``fd``, ``git``, and a configured model. Those stay host requirements, named
in the README. The binary ships Elixir, not the sandbox.

The payload: glibc, because that is what the NIFs are
-----------------------------------------------------

Burrito's default ERTS is a **musl** build. Both NIFs in this project are
built by the host: ``ex_ratatui`` from Rust (ADR 035) and ``exqlite`` from C.
In a musl ERTS they fail at load time with ``Error loading shared library
libgcc_s.so.1: Exec format error`` (or ``__memmove_chk: symbol not found``).
The target therefore supplies a glibc ERTS:

.. code-block:: elixir

    custom_erts:
      System.get_env("BURRITO_CUSTOM_ERTS") ||
        Path.join(to_string(:code.root_dir()),
                  "erts-#{:erlang.system_info(:version)}")

The exact running ERTS, not the OTP root: the root holds several ``erts-*``
directories and Burrito takes the first, which is not necessarily the one
this build was compiled against. ``BURRITO_CUSTOM_ERTS`` overrides for a
build that packages another glibc ERTS.

``skip_nifs: true`` is the other half. Burrito treats **every** Linux target
as a cross-build and recompiles NIFs with ``zig cc ... -shared``. For
``exqlite`` that link leaves an unversioned ``NEEDED libc.so`` behind, which
a glibc loader refuses (``/lib64/libc.so: invalid ELF header``); for an
executable helper such as ``exile``'s ``spawner`` the same flag corrupts the
entry point. Since this is a native build, the host-compiled NIFs are the
correct ones and must be left alone.

Measured on 2026-11-22, with the payload freshly extracted:

- ``maintenance meta`` reports ``skip_nifs: true`` and
  ``custom_erts: "/usr/lib64/erlang/erts-16.4.0.4"``;
- the packaged ``sqlite3_nif.so`` is byte-identical to the release's own
  (``NEEDED libc.so.6``), and ``ex_ratatui.so`` carries the same glibc
  dependencies;
- the binary starts the TUI in a 40x120 terminal, paints the whole frame,
  reads keys, and ctrl-c exits 0.

One operational trap: Burrito extracts the payload once per app version
under ``$XDG_DATA_HOME/.burrito/coding_agent_erts-<erts>_<version>`` and
reuses it. Rebuilding the wrapper without bumping ``version:`` therefore
keeps running the previously extracted payload — remove that directory (or
bump the version) before testing a new build. This cost time while
diagnosing the NIF failures above.

A second, measured on the same build: the wrapper does not translate
``eval``. ``burrito_out/coding_agent_linux eval 'IO.puts("PROBE")'`` prints
the app's own startup line, never runs the expression, and does not exit —
it starts the TUI and waits for keys, which on stdin that is not a tty looks
like a hang (measured: no output, ``timeout`` after 15 s). The diagnostic
form that does work is the extracted payload's own release script,
``<payload>/bin/coding_agent eval …``: it reports ``erts:
<payload>/erts-16.4.0.4`` and starts both NIF applications. Use that one,
and do not script ``eval`` through the wrapper.

Why 1.5.0 and not 1.6.0
-----------------------

1.6.0 is the Zig 0.16 port and is unusable for this application for three
reasons, all filed upstream and still open:

- **It pipes the BEAM's stdout unconditionally** (``.stdout = .pipe`` plus a
  copy thread) to detect EPIPE from a downstream consumer. OTP's ``prim_tty``
  requires *both* stdin and stdout to be TTYs, so the tty backend is disabled:
  the app can still draw, but cannot enter raw mode, read a key or query the
  terminal size. That is Burrito issue #234, with a fix proposed in PR #235
  (inherit stdout when ``isatty``). A terminal UI is exactly the case this
  breaks.
- **It runs Elixir's CLI.** 1.6.0 splits the ``-s elixir start_cli`` argument
  that 1.5.0 passed as one unrecognised element, so ``start_cli`` actually
  runs, claims the application's plain arguments and halts the VM after
  boot (#229). Long-running applications exit on their own; ours would lose
  the CLI that ``Application.start/2`` just spawned.
- **``-mode embedded`` is passed as a single argv element** (#233), so the VM
  boots interactive and loses embedded-mode semantics.

An earlier note in this ADR said 1.6.0 put ``stdin``/``stderr`` on
``/dev/null``. That was wrong: Zig 0.16's ``SpawnOptions`` defaults all three
streams to ``.inherit``, and Burrito overrides only stdout. The symptoms were
real; the descriptor named as the cause was not.

The pin is therefore not a workaround for one flag. 1.5.0 wants Zig 0.15.2,
which is the version the distribution ships, and it ``execve``\ s the BEAM so
every descriptor and the controlling terminal are inherited. Burrito is
archived on 2026-11-30, so waiting for #229/#233/#235 to land is not a plan;
if a maintained fork appears, those three patches are what to look for.

Consequences
------------

- One ``releases/0`` entry and one build step are the entire Burrito surface.
  Deleting ``&Burrito.wrap/1`` leaves an ordinary ``mix release`` tarball, so
  an unmaintained wrapper costs a build script, not a rewrite. That is the
  whole mitigation for the archive date, and it is deliberately cheap.
- Cross-targets wait for the NIF. ``ex_ratatui`` is built from Rust source
  (ADR 035), and Burrito's cross-build step recompiles **elixir-make C**
  NIFs only. A macOS or Windows binary needs a Rust cross-compilation story
  before it is a packaging question.
- The release payload redistributes ERTS (EPL-2.0) and the dependency BEAM
  files. The source tree's REUSE coverage does not describe a built artefact;
  notices for what a binary ships are a separate, still open question.
- ``mix test`` now also compiles ``CodingAgent.CLI`` and the handler, because
  the Mix task no longer owns them; the two tests that pin ``await_tui/3``
  and the log handler moved with them.

Alternatives
-------------

- **escript.** Smaller and simpler, but it needs a system Erlang — exactly the
  dependency the binary is meant to remove.
- **Plain ``mix release`` + tarball.** Works today and stays the fallback, but
  it is not a single file and still needs an unpack step.
- **Bakeware.** Archived, and superseded by Burrito by its own README.
- **No binary until CI exists.** Defensible, but the binary is the artefact a
  collaborator can actually run; the CI question is orthogonal and still open.
