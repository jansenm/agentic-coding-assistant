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
  def model do
    Application.fetch_env!(:coding_agent, :model)
  end
end
