defmodule CodingAgent do
  @moduledoc """
  CodingAgent — an agentic coding assistant for the terminal.

  Entry point module; functional code lives under the `CodingAgent.*`
  namespaces with the ADR 008 boundary rule:

  - `CodingAgent.Core.*` — agent loop, HITL, memory, tools (no UI deps)
  - `CodingAgent.UI.*`   — terminal driver (no LLM deps)
  """

  @doc """
  The configured model spec (req_llm format, e.g. "ollama:qwen3:14b").

  Resolution: the AGENT_MODEL env override (adhoc/live probes must not
  burn metered cloud quota — a cheap local model can be selected per
  run), then config.toml `model =` (project over global, ADR 014).
  No model name is baked into code; when neither source has one the
  result is nil and the caller decides (TUI: hard error today, a
  warning + in-session pick once the model menu exists).
  """
  @spec model() :: String.t() | nil
  def model do
    System.get_env("AGENT_MODEL") ||
      CodingAgent.Core.UserConfig.load(nil).config["model"]
  end
end
