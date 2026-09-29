:orphan:

ex_ratatui's NIF is built from source (native render crash workaround)
======================================================================

.. adr::
   :id: 035
   :status: Accepted
   :date: 2026-09-29
   :tags: ui, dependencies, native, crash

.. note::
   Accepted and implemented 2026-09-29. The app builds ex_ratatui's NIF
   from source with a conservative Cargo profile instead of using the
   shipped v0.13.1 precompiled artifact, which crashes in the render NIF.
   This is a mitigation, not a root-cause fix: it changes the build and
   the corruption suspect (fat LTO), and it stays until the crash is
   either reproduced on the source build or fixed upstream.

Context
-------

Between 2026-09-13 and 2026-09-29 the TUI died four times with an
identical native fault (``coredumpctl``, ``erl_crash``-less — the BEAM
takes no Elixir exception):

- SIGSEGV (``SEGV_MAPERR``), faulting address ``0x0``
- Backtrace: ``#0 0x0`` → the ex_ratatui NIF at fixed offsets
  (``+0x228255`` and ``+0x1f1a9e``) → ``erts_call_dirty_nif``
- The only ``DirtyIo`` render NIF is ``draw_frame``
  (``native/ex_ratatui/src/rendering.rs``); the frame resolves to
  ``render_widget_data``

All four crashes are byte-identical in signature, across ``mix tui`` and
``mix do clean + compile + tui``. The crashes happened while a turn was
streaming and the UI was repainting frequently with popups open, but no
single Elixir-side input reproduces it: it is intermittent in timing yet
deterministic in the fault address.

The register dump of the most recent crash is the tell: the return
address is the instruction after ``call *0x…(%rip)`` through the GOT
slot for ``clock_gettime``, and that slot read ``0x0``. The library is
linked ``BIND_NOW`` (full RELRO), where a null GOT slot after relocation
is impossible — so the GOT page itself was corrupted. This is native
memory corruption inside the NIF, not a missing symbol and not reachable
from our Elixir code.

A strong suspect is v0.13.1's own release profile: that version changed
the crate to ``strip = "symbols"``, fat **LTO**, and
``codegen-units = 1``. Fat LTO across the whole dependency graph —
including the ratatui blit paths that write raw buffer indices — is a
plausible source of cross-CGU miscompilation/corruption. Nothing in the
upstream changelog 0.14.0–0.16.0 documents a fix for this signature:
0.14.1 covers only aarch64/riscv glibc load-time refusal, 0.14/0.15 the
image/sixel paths, 0.16 a ``Textarea.wrap_mode`` feature.

Decision
--------

**1. Force a source build of the ex_ratatui NIF.** ``:rustler`` is
declared explicitly (it is an optional dependency of ex_ratatui and
optional deps are not fetched transitively), and
``config :rustler_precompiled, :force_build, ex_ratatui: true`` makes
``ExRatatui.Native`` compile the crate instead of downloading the
precompiled artifact. The runtime then loads ``priv/native/ex_ratatui``
(the source build), not
``libex_ratatui-v0.13.1-nif-2.17-…``.

**2. Override the release profile with a conservative one.** The crate's
own ``Cargo.toml`` still requests fat LTO; ``config :ex_ratatui,
ExRatatui.Native, env: [...]`` forwards
``CARGO_PROFILE_RELEASE_LTO=false`` and
``CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16`` to cargo, which overrides the
manifest profile. This directly tests the LTO hypothesis and produces a
5.6 MB artifact instead of 4.75 MB.

**3. Keep the API and the pin.** This changes nothing about how the app
uses ex_ratatui (same 0.13.1 API) and does not lift the ``~> 0.13``
constraint. It only changes which bytes of native code run.

Consequences
------------

- A source build needs a Rust toolchain on the build host (cargo/rustc;
  verified present: rustc 1.95). The precompiled path needed none, so a
  host without Rust can no longer build the app. Accepted: this is a
  single-developer alpha, and the alternative is a crash.
- The worktree that crashed (``agentic-coding-assistant-mjansen``) has
  its own ``deps/``; the mitigation reaches it only after the change
  merges and it recompiles. Until then it keeps the crashing precompiled
  artifact.
- If the crashes stop, that corroborates LTO — but does not prove it;
  the fault was intermittent. If they continue on the source build, the
  corruption is in the crate's logic, and the next step is an upstream
  report (issues are restricted; a discussion/PR) with the coredump.
- The config carries a delete-me comment: once a fixed ex_ratatui release
  lands, drop ``force_build`` and the explicit ``:rustler`` dep.

Open questions
--------------

1. **Report upstream?** The evidence (fixed offsets, null GOT under
   ``BIND_NOW``, the LTO profile change in 0.13.1) is worth an upstream
   discussion even before we know whether the source build fixes it.
2. **Diagnostic build instead of mitigation?** A debug-info source build
   would name the faulting function exactly, at the cost of a slow,
   non-production NIF. Deferred: the conservative release build is what
   we can ship; the debug build is a separate one-off.
