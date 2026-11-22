# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

import Config

# The two entry points to the TUI (ADR 048).
#
# A release boots through `CodingAgent.Application.start/2` and has no
# `mix tui`, so the application starts the CLI itself. `:prod` is the
# release environment; a checkout (`mix tui`, `mix test`) keeps the flag
# off and starts the TUI from the task, exactly once.
if config_env() == :prod do
  config :coding_agent, run_cli: true
end
