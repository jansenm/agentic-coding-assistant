# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule Mix.Tasks.Tui do
  @moduledoc """
  The terminal UI in a checkout. The work lives in `CodingAgent.CLI`, which
  is also what the release (the Burrito binary) starts.

      mix tui                          # fresh session, empty transcript
      mix tui "run the test suite"     # fresh session + initial prompt
      mix tui --resume <id>            # continue a persisted session
      mix tui --store <name|path>      # use a specific session store

  The session store (ADR 020 R16) is a directory; `--store` names one
  from config.toml `[stores]` or gives a path (`AGENT_STORE` and
  `config.toml store =` do the same without the flag).
  """

  use Mix.Task

  @shortdoc "Run the coding-agent terminal UI"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start", [])
    CodingAgent.CLI.run(args)
  end
end
