# Third-party notices

This project is MPL-2.0 (see the project `LICENSE`, to be added). The
files listed here are third-party material redistributed under their own
licenses; they are **not** relicensed as MPL.

## opencode — prompt text

- **Upstream:** https://github.com/anomalyco/opencode
- **Path:** `packages/opencode/src/session/prompt/*.txt`
- **License:** MIT — full text in `LICENSES/MIT.txt`
- **Copyright:** © 2025 opencode

The system-prompt files under `priv/coding-agent/prompts/` are **adapted**
from opencode's per-model prompt files. We borrow their *structure and
per-model calibration*, which is knowledge we do not yet have data to
reproduce (the upstream set is nine files, tuned over many releases).

What we changed, and why the result is our own file rather than a
verbatim copy:

- **Identity is rewritten.** The upstream files open "You are opencode…"
  and point at opencode's documentation and issue tracker. Redistributing
  that verbatim would instruct this agent to impersonate another project
  and route users to the wrong tracker. Every identity and URL line is
  ours.
- **Tool names are rewritten** to this project's canonical tools
  (`read_file`, `grep`, `glob`, `edit`, `write_file`, `shell`, `git`),
  not opencode's (`read`, `bash`, `write`, …).
- **Harness description is ours** (the TUI, the approval dialog, agent
  switching).
- The retained material is the *calibration*: the tone/brevity rules, the
  code-style rule, the tool-usage discipline, and the worked examples.

Because the retained material is substantial, the attribution above and
in `LICENSES/MIT.txt` is required and intentional.
