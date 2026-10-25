defmodule CodingAgent.Core.Session.Prompt do
  @moduledoc """
  System-prompt composition for a session (P3 factoring; ADR 024).

  The prompt is built from layers, in order:

    1. the framework prompt **selected for the model** (or a
       caller-supplied replacement),
    2. the project memory (`AGENTS.md`, `Core.ProjectMemory`),
    3. the agent definition's prompt (ADR 017), when one is selected.

  Layers 1-3 form the STABLE, persisted prefix (`base_prompt` +
  agent body), stored in the first context message. Everything that can
  change DURING a session is not part of it: it rides ONE trailing
  `<system-reminder>` message, rebuilt per call (ADR 024):

    * the **environment block** (`environment/2`) — the model id, the
      working directory, the platform, the date. Baking that into the
      stored prompt would make it stale and non-cacheable;
    * the **todo block** (`with_todos/2`, ADR 031) — the model's current
      list, rebuilt from session state per call so compaction cannot eat
      it;
    * the **budget block** (`with_budget/2`) — how full the context window
      is and where the two auto-summary lines sit, rebuilt per call for
      the same reason. It is a `%ContextBudget{}`, not a map: the numbers
      it renders are all required, so a producer that omits one fails to
      compile instead of silently dropping a clause from the block;
    * the **capability block** (`with_capabilities/2`) — what this
      session may NOT do: the tools the policy/agent removed from the
      registry and whether the shell root is read-only. The tool list
      can express "not present" but not "absent because forbidden" and
      not a filesystem bound; the block states both, so the model says
      what it lacks instead of spending calls discovering it.
    * the model selection that chose layer 1. A model switch recomposes
      the prefix (see `Session`), so the framework prompt follows the
      model the next turn will actually use.

  The POSITION is the point. A provider caches on the exact request
  prefix, so a byte that changes at the FRONT throws away the cache for
  every byte behind it. These blocks used to be appended to the system
  message — the first byte of the request — so every round whose block
  changed paid a full re-prefill: a 121k context costs ≈2 ¢ cold, and a
  `todowrite` changed the todo block, which made a 2 ¢ round out of a
  round whose new content was a few hundred tokens. At the tail the same
  change costs only the tail, which is re-sent on every round anyway.

  This module is pure string work — it reads prompt files and composes
  strings; it touches no session state and no clock beyond the date.
  """

  alias CodingAgent.Core.Session.ContextBudget

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
  directory, the harness it is running in, platform, date. Appended to the
  system message ON THE WIRE only — never persisted, because it changes
  every call.

  The block also names the SESSION the model cannot infer from the tree:

    * the git branch and whether the scope root is a linked WORKTREE
      (``git worktree list`` is otherwise a tool round just to learn
      "which checkout am I in");
    * the agent mode (``plan`` = read-only, ``build`` = read-write) and the
      shell root mode — the same ``Shell root`` fact the capability block
      states for a read-only root;
    * the session store in use (checkpoint refs are store-namespaced).

  ``opts`` carries the per-session facts the composition already resolved:
  ``:agent`` (mode), ``:shell_mode`` (policy) and ``:store`` (the pinned
  store path). All optional: a pure string-level call (a test, an older
  caller) emits the same block as before, so this stays a pure prompt
  function.
  """
  @spec environment(String.t() | nil, String.t() | nil, keyword()) :: String.t()
  def environment(model, scope_root, opts \\ []) do
    dir = scope_root || File.cwd!()

    lines =
      [
        {"Model", model || "unknown"},
        {"Working directory", dir},
        {"Is directory a git repo", if(git_repo?(dir), do: "yes", else: "no")}
      ] ++
        git_lines(dir) ++
        agent_lines(opts) ++
        [{"Platform", platform()}] ++
        store_lines(opts) ++
        [
          {"Today's date", "#{Date.utc_today()}"},
          {"Harness", harness()}
        ]

    body = Enum.map_join(lines, "\n", fn {label, value} -> "  #{label}: #{value}" end)

    """
    Here is some useful information about the environment you are running in:
    <env>
    #{body}
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
  Rides the trailing state message with the environment block (see the
  moduledoc). The stored context is untouched: the block is rebuilt per
  call so its date and model are current (ADR 024).
  """
  @spec with_environment(ReqLLM.Context.t(), String.t() | nil, String.t() | nil, keyword()) ::
          ReqLLM.Context.t()
  def with_environment(context, model, scope_root, opts \\ []) do
    append_state_block(context, environment(model, scope_root, opts))
  end

  @doc """
  Rides the trailing state message with the model's current todo list
  (ADR 031). An empty list adds nothing, so a session that never plans
  sends an unchanged request.

  This is the channel that survives compaction: the list is not an old
  message that can be summarized away, it is rebuilt from live session
  state on every request — the same reason the environment block is
  per-call (ADR 024). Riding the TAIL also matters here: the list is what
  the model itself rewrites, so a `todowrite` changes it mid-turn; at the
  tail that costs the tail, in the system message it cost the context.
  """
  @spec with_todos(ReqLLM.Context.t(), [map()]) :: ReqLLM.Context.t()
  def with_todos(context, todos) do
    case todos_block(todos) do
      nil -> context
      block -> append_state_block(context, block)
    end
  end

  @doc """
  Rides the trailing state message with the context-budget block — the
  same per-call channel as the environment and todo blocks: rebuilt from
  live session state every request, so it is always current and
  compaction cannot eat it.

  The block speaks in BANDS, never in numbers. The soft/hard passes fire
  on the same numbers as before, and the block tells the model which line
  it is near so it can choose to finish a step and end its turn (which
  triggers the soft pass) rather than have it happen mid-think.

  It used to carry the exact counts — projected size, window percentage,
  distance to each line, the round counter — and those moved on every
  round of a turn. A provider caching on the exact prefix could never
  hit: measured at 8 960 of 9 049 tokens cached with a stable first
  message and 0 with one line changed. That was true because the block
  sat in the system message, AHEAD of every other byte; the band fixed
  the numbers, and the tail (see the moduledoc) means even a band flip
  changes only the tail. The numbers still exist, in the sidebar, for
  the human (ADR 029); the model acts on the band.

  It is not purely "visibility" any more: since the `compact` tool exists
  (ADR 040 OQ1, answered 2026-09-30) the block also names that lever, so
  the model can summarize NOW instead of only ending its turn. The lever
  is mentioned in the calm case too — one line that never changes costs
  no cache — so the model knows the verb exists before it is at a wall.

  Takes a `%ContextBudget{}`, not a map: every field travels from
  `Session` to this module, so a missing one is a compile error at the
  producer instead of a band that silently never fires.
  """
  @spec with_budget(ReqLLM.Context.t(), ContextBudget.t()) :: ReqLLM.Context.t()
  def with_budget(context, %ContextBudget{window: window} = budget) when window > 0 do
    case budget_block(budget) do
      "" -> context
      block -> append_state_block(context, block)
    end
  end

  def with_budget(context, _), do: context

  @doc """
  Rides the trailing state message with the capability block — the same
  per-call channel as the environment and budget blocks (ADR 024),
  rebuilt from live policy state so it is always current.

  It states what this session CANNOT do, ahead of any attempt:

    * the tools that are not in the request's tool set at all
      (`edit`, `write_file`, `git` under the plan agent) — a call to
      them fails with "unknown tool"; the model otherwise learns this
      by spending a round on the attempt;
    * a read-only shell root (`shell = "read_only"`) — the one
      capability the tool list can never express, because `shell` IS
      present and only the filesystem bound is narrower. Builds, tests
      and any write inside the tree fail with a read-only filesystem
      error.

  The `gate` map (from `Session.gate_decisions/1`) additionally names
  the exposed tools whose policy decision is `:ask` — derived THROUGH
  the gate's own `Gate.decision/4`, so the statement and the gate can
  never disagree. The framing is deliberate: approval is the mechanism
  that keeps the human in control, and the cost is one keystroke — not
  a refusal, and not a reason to avoid the call.

  Nothing to say means no block: a fully equipped read-write session
  with no ask-policies sends an unchanged request, exactly like an empty
  todo list.

  The block is a COST statement, not a security boundary — the gate and
  the sandbox enforce; this only tells the model the shape of the
  session before it pays for discovering it.
  """
  @spec with_capabilities(ReqLLM.Context.t(), %{
          missing: [String.t()],
          shell_mode: atom(),
          gate: %{String.t() => atom()} | nil
        }) :: ReqLLM.Context.t()
  def with_capabilities(context, %{missing: missing, shell_mode: shell_mode} = info) do
    case capabilities_block(missing, shell_mode, Map.get(info, :gate)) do
      nil -> context
      block -> append_state_block(context, block)
    end
  end

  def with_capabilities(context, _), do: context

  # The block text, or nil when there is nothing to state: full
  # capabilities, read-write shell, and no exposed tool whose decision
  # is `:ask`. The wording mirrors what the failures look like ("unknown
  # tool", "read-only filesystem"), so a call that slips through anyway
  # is recognisable as the stated limit and not a new problem.
  defp capabilities_block([], :rw, gate) do
    case ask_block(gate) do
      nil -> nil
      ask -> "Session capabilities: #{ask}."
    end
  end

  defp capabilities_block(missing, shell_mode, gate) do
    tool_clause =
      case missing do
        [] ->
          nil

        names ->
          "you do not have the #{Enum.join(names, ", ")} tool(s) " <>
            "(calls to them fail with \"unknown tool\")"
      end

    shell_clause =
      case shell_mode do
        :ro ->
          "the shell runs with the scope root READ-ONLY: builds, tests and any " <>
            "command that writes inside the tree fail with a read-only filesystem " <>
            "error — do not retry them"

        _ ->
          nil
      end

    clauses = Enum.reject([tool_clause, shell_clause], &is_nil/1)

    base =
      "Session capabilities: " <>
        Enum.join(clauses, "; ") <> "."

    case ask_block(gate) do
      nil ->
        base <>
          " Say what you would change and hand the exact edits to the human or " <>
          "a build agent instead."

      ask ->
        base <> " " <> ask
    end
  end

  # The ask clause. A SEPARATE sentence with its own framing: approval is
  # the mechanism that keeps the human in control, not a deficit — the
  # cost is one keystroke, and the call should be MADE when the step is
  # worth it. Derived from `Session.gate_decisions/1` (the gate's own
  # `decision/4` per exposed tool), so this text and the next gate
  # decision cannot disagree.
  defp ask_block(gate) when is_map(gate) do
    asked =
      gate
      |> Enum.filter(fn {_tool, d} -> d == :ask end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case asked do
      [] ->
        nil

      names ->
        "#{Enum.join(names, ", ")} require the human's approval when you call " <>
          "them (one keystroke, not a refusal) — use them when the step is worth it"
    end
  end

  defp ask_block(_), do: nil

  # The budget block, as a BAND. `used` is the projected tokens (provider
  # count or chars/4, whichever is larger — the same value the compaction
  # decision uses); soft is the turn-end trigger, hard the pre-call one.
  # `rounds`/`max_rounds` are the TOOL-ROUND budget the guard checks
  # (ADR 025).
  #
  # Every number left this text (ADR 040, amendment 2026-10-24). They
  # moved on every round of a turn, and the block sits in the system
  # message — ahead of every other byte — so a provider caching on the
  # exact prefix could never hit: measured 8 960 of 9 049 tokens cached
  # with a stable first message, 0 with one line changed. The numbers are
  # still in the sidebar for the human (ADR 029); the model acts on the
  # band, which is the same decision ADR 040 asked for.
  defp budget_block(%ContextBudget{} = budget) do
    [context_band(budget), rounds_band(budget)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # The calm line still names the lever (ADR 040 OQ1: the model should
  # know the verb exists before it is at a wall) — and being constant, it
  # costs no cache. Below the warn line it is the ONLY line, which is what
  # makes the first message byte-stable for most of a turn.
  defp context_band(%ContextBudget{used: used, soft: soft, hard: hard, warn_at: warn_at}) do
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

      used >= warn_at ->
        "You are approaching the soft line. Two ways to act before the hard limit " <>
          "forces it: end your turn at a step boundary (the idle pass then summarizes " <>
          "with headroom, at no latency cost to your next prompt), or call `compact` " <>
          "to free room inside this turn. Either way, put durable facts (paths, " <>
          "numbers, decisions) in a todo's `notes` first — notes survive " <>
          "summarization, older messages do not."

      true ->
        "Context budget: there is room. The `compact` tool summarizes the older span " <>
          "when a step needs more headroom."
    end
  end

  # The tool-round band: the guard the model cannot otherwise see (ADR 025),
  # now stated only when it matters. One flip near the end of a long turn is
  # one cache miss; a counter on every round was one per round.
  @round_band_fraction 0.8

  defp rounds_band(%ContextBudget{rounds: rounds, max_rounds: max}) when max > 0 do
    cond do
      rounds >= max ->
        "This turn has reached its tool-round budget; the harness wraps the turn up now."

      rounds >= ceil(max * @round_band_fraction) ->
        "This turn has used most of its tool-round budget; finish the current step " <>
          "rather than opening a new one."

      true ->
        nil
    end
  end

  defp rounds_band(_), do: nil

  # The upkeep rule, ON THE BLOCK ITSELF and only when a list exists. It is
  # the ONE sentence the tool description does not carry: that a FINISHED
  # list must be CLEARED, not left standing. The other two rules ("mark
  # `completed` as soon as it is done", "not in a batch at the end") already
  # live in the tool description and the framework prompt, so repeating them
  # here — on the UNCACHED channel, every request — was duplication (review
  # N80). Proximity is kept for the one instruction that has no other home.
  #
  # Cost: it rides every request that has a list, so it is one sentence.
  @todo_upkeep "\n\nKeep it current: when the task is finished, send `[]` " <>
                 "— a stale plan misleads the human watching it."

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
      items <> @todo_upkeep
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

  # The per-call state channel: ONE trailing user message wrapping every
  # block, so a block that changes moves only the tail of the request and
  # the cached prefix is untouched (see the moduledoc). Blocks are merged
  # in call order into the same message; only we produce this lead, so a
  # human message can never be mistaken for it.
  @state_open "<system-reminder>"
  @state_close "</system-reminder>"
  @state_lead @state_open <>
                "\nSession state, updated automatically on every request. " <>
                "It is not a message from the human; do not reply to it."

  defp append_state_block(context, block) do
    case List.last(ReqLLM.Context.to_list(context)) do
      %ReqLLM.Message{role: :user, content: [%ReqLLM.Message.ContentPart{text: text} = part]}
      when is_binary(text) ->
        if String.starts_with?(text, @state_lead) do
          body = String.replace_suffix(text, "\n" <> @state_close, "")
          replace_last(context, %{part | text: body <> "\n\n" <> block <> "\n" <> @state_close})
        else
          push_state(context, block)
        end

      _ ->
        push_state(context, block)
    end
  end

  defp push_state(context, block) do
    text = @state_lead <> "\n\n" <> block <> "\n" <> @state_close
    ReqLLM.Context.append(context, ReqLLM.Context.user(text))
  end

  defp replace_last(context, part) do
    {init, [last]} = context |> ReqLLM.Context.to_list() |> Enum.split(-1)
    ReqLLM.Context.new(init ++ [%{last | content: [part]}])
  end

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

  # -- environment-block fields the session supplies (P2) -------------------

  # The branch and worktree line: "which checkout am I in". A linked
  # worktree's `.git` is a FILE pointing at the main repository's
  # `<gitdir>/worktrees/<name>` — reading it is a file read, not a `git`
  # call, which keeps this block cheap. The branch comes from the
  # worktree's own HEAD ("<gitdir>/HEAD"). A detached HEAD shows the short
  # hash. A plain checkout shows its branch and no worktree suffix.
  defp git_lines(dir) do
    cond do
      not git_repo?(dir) ->
        []

      worktree_gitdir(dir) ->
        case worktree_head(worktree_gitdir(dir)) do
          nil -> [{"Git", "linked worktree (detached)"}]
          head -> [{"Git", "linked worktree, #{head}"}]
        end

      true ->
        case branch_head(Path.join(dir, ".git/HEAD")) do
          nil -> []
          head -> [{"Git", "branch #{head}"}]
        end
    end
  end

  # A linked worktree: `.git` is a FILE whose first line is
  # `gitdir: <main-repo>/.git/worktrees/<name>`. nil for a main checkout.
  defp worktree_gitdir(dir) do
    case File.read(Path.join(dir, ".git")) do
      {:ok, "gitdir: " <> path} -> path |> String.trim() |> resolve_gitdir(dir)
      _ -> nil
    end
  end

  # The pointer may be relative to the worktree dir (git writes absolute
  # paths for `git worktree add`, but a moved directory can leave it
  # relative). An absolute path is used as-is.
  defp resolve_gitdir(path, dir) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, dir)
  end

  defp worktree_head(gitdir), do: branch_head(Path.join(gitdir, "HEAD"))

  # "ref: refs/heads/<branch>" -> the branch; a detached HEAD (a raw hash)
  # -> the short hash; anything unreadable -> nil.
  defp branch_head(head_path) do
    case File.read(head_path) do
      {:ok, "ref: refs/heads/" <> branch} ->
        branch |> String.trim()

      {:ok, hash} ->
        hash |> String.trim() |> String.slice(0, 7)

      _ ->
        nil
    end
  end

  # The agent row: WHICH agent this session runs as. The name is the mode,
  # because the definition carries the read-only/write split (plan vs
  # build) and the capability block states the resulting tools and shell
  # root authoritatively — so this row names the actor, it does not
  # re-derive the capability. A subagent says so (it was not started by
  # the human). No row for a session with no definition.
  defp agent_lines(opts) do
    case Keyword.get(opts, :agent) do
      %{name: name, mode: :subagent} when is_binary(name) ->
        [{"Agent", "#{name} (subagent)"}]

      %{name: name} when is_binary(name) ->
        [{"Agent", name}]

      _ ->
        []
    end
  end

  # The store row: WHICH session database (checkpoint refs are
  # store-namespaced, so history questions are answered against this one).
  # Only when the session supplies it.
  defp store_lines(opts) do
    case Keyword.get(opts, :store) do
      store when is_binary(store) and store != "" -> [{"Store", store}]
      _ -> []
    end
  end

  # The harness line for the environment block. Named so the model knows
  # WHICH software it is running in, not only which machine: this repo is
  # both the harness and the product, so a reviewing agent otherwise has
  # to infer "the thing I am inside is the thing I am reading".
  #
  # The product has no name of its own yet — README calls it "CodingAgent",
  # `mix.exs` the app `:coding_agent`. When it gets one, this is the ONE
  # place to change: the ADR 024 field list is updated with it.
  @harness "CodingAgent (agentic coding assistant, unreleased)"
  @spec harness() :: String.t()
  def harness, do: @harness

  defp platform do
    case :os.type() do
      {:unix, :linux} -> "linux"
      {:unix, :darwin} -> "darwin"
      {:win32, _} -> "win32"
      {_, other} -> to_string(other)
    end
  end
end
