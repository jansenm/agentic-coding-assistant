defmodule CodingAgent do
  @moduledoc """
  CodingAgent — an agentic coding assistant for the terminal.

  Entry point module; functional code lives under the `CodingAgent.*`
  namespaces with the ADR 008 boundary rule:

  - `CodingAgent.Core.*` — agent loop, HITL, memory, tools (no UI deps)
  - `CodingAgent.UI.*`   — terminal driver (no LLM deps)
  """

  @doc """
  The configured model spec (req_llm format, e.g. "anthropic:claude-haiku-4-5").
  """
  @spec model() :: String.t()
  # Adhoc/live probes must not burn metered cloud quota: the model can
  # be overridden per run with AGENT_MODEL (cheap local/free model),
  # e.g. AGENT_MODEL="ollama:nemotron-3-ultra:cloud" mix tui
  def model do
    System.get_env("AGENT_MODEL") || Application.fetch_env!(:coding_agent, :model)
  end
end
