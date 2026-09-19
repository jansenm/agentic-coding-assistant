defmodule CodingAgent.Core.Session.Prompt do
  @moduledoc """
  System-prompt composition for a session (P3 factoring).

  The prompt is built from three layers, in order:

    1. the framework prompt (or a caller-supplied replacement),
    2. the project memory (`AGENTS.md`, `Core.ProjectMemory`),
    3. the agent definition's prompt (ADR 017), when one is selected.

  This knew nothing else and is pure string work — it lived in `Session`
  because the session happened to call it, not because it belongs to the
  turn loop.

  `base_prompt/1` is layer 1+2 (before any agent): a later agent switch
  (`set_agent/2`, Tab) recomposes from this so definitions never compound
  (`apply_agent` is narrowing, not idempotent).
  """

  @framework_prompt """
  You are a coding assistant embedded in a terminal tool. Be concise and
  precise. When you intend to use a tool, emit the tool call; do not
  narrate that you are about to call tools.
  """

  @doc "The built-in framework prompt (the default first layer)."
  @spec framework() :: String.t()
  def framework, do: @framework_prompt

  @doc """
  The base prompt: framework (or `override`) plus the project memory for
  `scope_root`. This is the value stored as `base_prompt`.
  """
  @spec base(String.t() | nil, String.t() | nil) :: String.t()
  def base(override, scope_root) do
    override = override || @framework_prompt
    CodingAgent.Core.ProjectMemory.append(override, scope_root)
  end

  @doc """
  Composes an agent definition's prompt onto an existing prompt. A blank
  agent prompt leaves the base unchanged.
  """
  @spec compose_agent(String.t(), String.t()) :: String.t()
  def compose_agent(base_prompt, agent_prompt) do
    case String.trim(agent_prompt) do
      "" -> base_prompt
      prompt -> base_prompt <> "\n\n" <> prompt
    end
  end

  @doc """
  Replaces the system message (the first message, at index 0) in a
  context with `prompt`, keeping every other message. A context without a
  system message gets one prepended.
  """
  @spec replace_in_context(ReqLLM.Context.t(), String.t()) :: ReqLLM.Context.t()
  def replace_in_context(context, prompt) do
    messages = ReqLLM.Context.to_list(context)

    case messages do
      [%ReqLLM.Message{role: :system} | rest] ->
        ReqLLM.Context.new([ReqLLM.Context.system(prompt) | rest])

      _ ->
        ReqLLM.Context.new([ReqLLM.Context.system(prompt) | messages])
    end
  end
end
