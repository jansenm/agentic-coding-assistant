defmodule CodingAgent.Core.Session.Prompt do
  @moduledoc """
  System-prompt composition for a session (P3 factoring; ADR 024).

  The prompt is built from layers, in order:

    1. the framework prompt **selected for the model** (or a
       caller-supplied replacement),
    2. the project memory (`AGENTS.md`, `Core.ProjectMemory`),
    3. the agent definition's prompt (ADR 017), when one is selected.

  Layers 1-3 form the STABLE, persisted prefix (`base_prompt` +
  agent body), stored in the first context message. Two things are NOT
  part of it, both per-call (ADR 024):

    * the **environment block** (`environment/2`) — the model id, the
      working directory, the platform, the date. Baking that into the
      stored prompt would make it stale and non-cacheable;
    * the **todo block** (`with_todos/2`, ADR 031) — the model's current
      list, rebuilt from session state per call so compaction cannot eat
      it;
    * the **budget block** (`with_budget/2`) — how full the context window
      is and where the two auto-summary lines sit, rebuilt per call for
      the same reason. Visibility only: it does not change when
      summarization happens;
    * the model selection that chose layer 1. A model switch recomposes
      the prefix (see `Session`), so the framework prompt follows the
      model the next turn will actually use.

  This module is pure string work — it reads prompt files and composes
  strings; it touches no session state and no clock beyond the date.
  """

  @prompts_dir_path "coding-agent/prompts"

  # Last-resort prompt if the priv files cannot be read (a broken build).
  # An empty system prompt is worse than a short one.
  @minimal "You are a coding assistant embedded in a terminal application. Be concise."

  # The wrap-up instruction sent when a turn reaches its tool-round budget
  # (ADR 025). Tools are withheld on that call, so this only has to steer
  # the prose; the wording is ours (opencode's MAX_STEPS_PROMPT is the
  # reference, not the source — identity and requirements rewritten).
  @wrap_up """
  The tool-round budget for this turn has been reached, so no further tools
  are available. Respond with text only — do not attempt to call any tool.

  In your response:
  - state that the turn's tool budget was reached;
  - summarize what you accomplished;
  - list what is still unfinished;
  - recommend the next step for the human.\
  """

  @doc "The turn-budget wrap-up instruction (ADR 025)."
  @spec wrap_up() :: String.t()
  def wrap_up, do: @wrap_up

  # Model families we ship a calibrated framework prompt for (ADR 024).
  # The default is the strict, example-light one tuned for local models;
  # a Claude variant exists because Claude responds to a different frame
  # (objectivity, heavier todo use, looser brevity). Adding a family is a
  # new data file plus an entry here — start with two, not nine.
  @family_matchers [
    {~r/claude/i, "claude"}
  ]

  @doc "The framework prompt for a model spec (`provider:model-id`)."
  @spec framework(String.t() | nil) :: String.t()
  def framework(model \\ nil) do
    read("#{family(model)}.txt")
  end

  @doc """
  The model family whose prompt file to use. Unknown models get
  `"default"` — the strict calibration, correct for local and
  unclassified models.
  """
  @spec family(String.t() | nil) :: String.t()
  def family(model) when is_binary(model) do
    case Enum.find(@family_matchers, fn {re, _} -> Regex.match?(re, model) end) do
      {_re, name} -> name
      nil -> "default"
    end
  end

  def family(_), do: "default"

  @doc """
  The base prompt: the framework prompt for `model` (or `override`) plus
  the project memory for `scope_root`. This is the value stored as
  `base_prompt`.
  """
  @spec base(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def base(override, scope_root, model \\ nil) do
    override = override || framework(model)
    CodingAgent.Core.ProjectMemory.append(override, scope_root)
  end

  @doc """
  The per-call environment block (ADR 024): model identity, working
  directory, platform, date. Appended to the system message ON THE WIRE
  only — never persisted, because it changes every call.
  """
  @spec environment(String.t() | nil, String.t() | nil) :: String.t()
  def environment(model, scope_root) do
    dir = scope_root || File.cwd!()

    """
    Here is some useful information about the environment you are running in:
    <env>
      Model: #{model || "unknown"}
      Working directory: #{dir}
      Is directory a git repo: #{if git_repo?(dir), do: "yes", else: "no"}
      Platform: #{platform()}
      Today's date: #{Date.utc_today()}
    </env>\
    """
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

  @doc """
  Appends the environment block to the system message of `context`,
  returning a context for ONE call. The stored context is untouched: the
  block is rebuilt per call so its date and model are current (ADR 024).
  """
  @spec with_environment(ReqLLM.Context.t(), String.t() | nil, String.t() | nil) ::
          ReqLLM.Context.t()
  def with_environment(context, model, scope_root) do
    append_system_block(context, environment(model, scope_root))
  end

  @doc """
  Appends the model's current todo list to the system message of
  `context`, returning a context for ONE call (ADR 031). An empty list
  adds nothing, so a session that never plans sends an unchanged
  request.

  This is the channel that survives compaction: the list is not an old
  message that can be summarized away, it is rebuilt from live session
  state on every request — the same reason the environment block is
  per-call (ADR 024).
  """
  @spec with_todos(ReqLLM.Context.t(), [map()]) :: ReqLLM.Context.t()
  def with_todos(context, todos) do
    case todos_block(todos) do
      nil -> context
      block -> append_system_block(context, block)
    end
  end

  @doc """
  Appends the context-budget block to the system message of `context`,
  returning a context for ONE call. The same per-call channel as the
  environment and todo blocks: rebuilt from live session state every
  request, so it is always current and compaction cannot eat it.

  The model gets the SAME numbers the human sees in the sidebar (ADR 029
  — the display must not show a different value than the decision uses):
  the projected context size, the window, and the two auto-summary lines.

  The automatic policy is unchanged: the soft/hard passes fire on the
  same numbers as before, and the block tells the model when they happen
  so it can choose to finish a step and end its turn (which triggers the
  soft pass) rather than have it happen mid-think. When nothing is near a
  limit the block is still sent — one constant-size line per request — so
  the model learns the metric instead of meeting it only at the wall.

  It is not purely "visibility" any more: since the `compact` tool exists
  (ADR 040 OQ1, answered 2026-09-30) the block also names that lever, so
  the model can summarize NOW instead of only ending its turn. The lever
  is mentioned in the calm case too, so
  the model knows the verb exists before it is at a wall.
  """
  @spec with_budget(ReqLLM.Context.t(), map()) :: ReqLLM.Context.t()
  def with_budget(context, %{window: window} = budget) when is_integer(window) and window > 0 do
    append_system_block(context, budget_block(budget))
  end

  def with_budget(context, _), do: context

  # The budget block text. `used` is the projected tokens (provider count or
  # chars/4, whichever is larger — the same value the compaction decision
  # uses); soft is the turn-end trigger, hard the pre-call one.
  defp budget_block(%{used: used, window: window, soft: soft, hard: hard}) do
    pct = trunc(used * 100 / max(window, 1))

    base =
      "Context budget: ~#{k(used)} / #{k(window)} tokens (#{pct}%). " <>
        "Older messages are summarized automatically at #{k(soft)} when your turn ends, " <>
        "and forced at #{k(hard)} before a call; you may also call the `compact` tool " <>
        "any time to summarize the older span now and free room."

    case guidance(used, soft, hard) do
      nil -> base
      guidance -> base <> "\n" <> guidance
    end
  end

  # The action hint, only once the model is actually near a line. Keeping it
  # out of the calm case avoids nagging a session that has room.
  defp guidance(used, soft, hard) do
    cond do
      used >= hard ->
        "You are at the hard limit: older messages will be summarized before your next " <>
          "call. Call `compact` now to do it deliberately, and record any fact you must " <>
          "keep in a todo's `notes` first."

      used >= soft ->
        "You are past the auto-summary line. Call `compact` when the current step is " <>
          "done to buy headroom without losing your place — and put durable facts " <>
          "(paths, numbers, decisions) in a todo's `notes` first; notes survive " <>
          "summarization."

      true ->
        nil
    end
  end

  defp k(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp k(n) when n >= 1_000, do: "#{div(n, 1_000)}k"
  defp k(n), do: to_string(n)

  # The todo block for the system prompt, or nil when there is no list.
  # Plain `[status] content` lines: the sidebar owns glyphs and color.
  @spec todos_block([map()]) :: String.t() | nil
  def todos_block([]), do: nil

  def todos_block(todos) when is_list(todos) do
    items =
      Enum.map_join(todos, "\n", fn todo ->
        status = todo["status"] || todo[:status] || "pending"
        content = todo["content"] || todo[:content] || ""
        "- [#{status}] #{content}#{notes_suffix(todo)}"
      end)

    "Current todo list (maintained with `todowrite`; send the complete list to update):\n" <>
      items
  end

  def todos_block(_), do: nil

  # The agent-private notes for an item, rendered as an indented sub-line
  # (or several). Not shown in the sidebar — only here, so the model reads
  # its own durable facts back on every request and compaction cannot eat
  # them (the same survival property the list itself relies on).
  defp notes_suffix(todo) do
    case todo["notes"] || todo[:notes] do
      notes when is_binary(notes) and notes != "" ->
        notes |> String.split("\n", trim: true) |> Enum.map_join("", &"\n    #{&1}")

      _ ->
        ""
    end
  end

  # Appends `block` to the system message (the first message) of
  # `context`, one blank line between. The stored context is untouched.
  defp append_system_block(context, block) do
    case ReqLLM.Context.to_list(context) do
      [%ReqLLM.Message{role: :system} = sys | rest] ->
        ReqLLM.Context.new([append_text(sys, block) | rest])

      _ ->
        context
    end
  end

  defp append_text(%ReqLLM.Message{content: parts} = msg, block) when is_list(parts) do
    %{msg | content: parts ++ [ReqLLM.Message.ContentPart.text("\n\n" <> block)]}
  end

  defp append_text(msg, block), do: msg |> ensure_parts() |> append_text(block)

  defp ensure_parts(%ReqLLM.Message{content: text} = msg) when is_binary(text) do
    %{msg | content: [ReqLLM.Message.ContentPart.text(text)]}
  end

  defp ensure_parts(msg), do: msg

  # -- Prompt files -----------------------------------------------------------

  defp read(name) do
    path = Path.join([Application.app_dir(:coding_agent), "priv", @prompts_dir_path, name])

    case File.read(path) do
      {:ok, text} -> String.trim_trailing(text)
      {:error, _} -> String.trim_trailing(read_fallback(name))
    end
  end

  # Test/build robustness: if the priv file is unavailable, fall back to
  # the default file; if even that is missing, a minimal prompt so this
  # never returns "" (an empty system prompt is worse than a short one).
  defp read_fallback("default.txt"), do: @minimal
  defp read_fallback(_name), do: fallback_file() || @minimal

  defp fallback_file do
    path =
      Path.join([Application.app_dir(:coding_agent), "priv", @prompts_dir_path, "default.txt"])

    case File.read(path) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end

  defp git_repo?(dir) do
    # A cheap filesystem check: a `.git` entry (dir for a checkout, file
    # for a worktree) at the scope root. We do not shell out to git.
    File.exists?(Path.join(dir, ".git"))
  end

  defp platform do
    case :os.type() do
      {:unix, :linux} -> "linux"
      {:unix, :darwin} -> "darwin"
      {:win32, _} -> "win32"
      {_, other} -> to_string(other)
    end
  end
end
