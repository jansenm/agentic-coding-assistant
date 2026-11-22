<!--
SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>

SPDX-License-Identifier: MPL-2.0
-->

# Third-party notices

This project is MPL-2.0 (see [`LICENSE`](LICENSE)). The files listed
here are third-party material redistributed under their own licenses;
they are **not** relicensed as MPL. Every file in the tree carries its
licensing as SPDX tags (or, where a header cannot be written, in
[`REUSE.toml`](REUSE.toml)); `reuse lint` is the check.

## opencode — prompt text

- **Upstream:** https://github.com/anomalyco/opencode
- **Path:** per-model system-prompt files (`.txt`) — at the revision this
  notice was last checked (2026-10-11, `7b3d4ce3a7`) they live at
  `packages/core/src/plugin/system-prompt/`
- **License:** MIT — full text in `LICENSES/MIT.txt`
- **Copyright:** © 2025 opencode

The system-prompt files under `priv/coding-agent/prompts/` are
**adapted** from opencode's per-model prompt files. We borrow their
*structure and per-model calibration*, which is knowledge we do not yet
have data to reproduce. We do not state a file count: the upstream set
has changed size repeatedly (it was one file at its earliest revision and
fifteen at its highest in the directory that preceded the current one),
so any number is stale on arrival.

What we changed, and why the result is our own file rather than a
verbatim copy:

- **Identity is rewritten.** The upstream files open with an opencode
  persona and point at opencode's documentation and issue tracker.
  Redistributing that verbatim would instruct this agent to impersonate
  another project and route users to the wrong tracker. Every identity
  and URL line is ours.
- **Tool names are rewritten** to this project's canonical tools
  (`read_file`, `grep`, `glob`, `edit`, `write_file`, `shell`, `git`),
  not opencode's (`read`, `bash`, `write`, …).
- **Harness description is ours** (the TUI, the approval dialog, agent
  switching) — the upstream files do not know this harness exists.
- **`Context budget` is ours and has no upstream counterpart** — it
  describes the budget line this harness emits (ADR 040), which opencode
  does not.
- **No worked examples.** Some upstream variants carry literal
  `<example>` blocks and sections such as `# Proactiveness` /
  `# Following conventions` / `# Code References`; our files carry none
  of these. Our `# Tone and style`, `# Doing tasks`, `# Code style` and
  `# Tool usage` cover the same ground as rules in our own words.

The retained material is the *calibration*: the tone/brevity rules, the
code-style rule, the tool-usage discipline. It is substantial, so the
attribution above and in `LICENSES/MIT.txt` is required and intentional;
how much of it is verbatim rather than restated is an open question in
ADR 024 rather than a claim made here.
