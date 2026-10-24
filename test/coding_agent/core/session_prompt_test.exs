defmodule CodingAgent.Core.Session.PromptTest do
  @moduledoc """
  Unit tests for the extracted prompt composition (P3). The session-level
  integration (agent switch recomposition, memory in the context) stays
  in the session/agent tests; these pin the layers and their order.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Session.{Compactor, ContextBudget, Prompt, State, Usage}

  setup do
    root = System.tmp_dir!() |> Path.join("prompt-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # The system message's text of a per-call context. ONE helper: it was
  # defined inside two `describe` blocks, which made the second definition
  # unreachable (the block compiler warns about it).
  defp system_text(context) do
    [%ReqLLM.Message{role: :system} = sys | _] = ReqLLM.Context.to_list(context)
    Enum.map_join(sys.content, "", &(&1.text || ""))
  end

  defp base, do: ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.system("BASE"))

  test "base/2 is framework + project memory, in that order", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), "PROJECT-RULE")

    base = Prompt.base(nil, root)

    assert base =~ "coding assistant"
    assert base =~ "PROJECT-RULE"
    # framework first, memory after
    assert :binary.match(base, "coding assistant") |> elem(0) <
             :binary.match(base, "PROJECT-RULE") |> elem(0)
  end

  test "base/2 honors a caller's prompt override", %{root: root} do
    assert Prompt.base("CUSTOM", root) =~ "CUSTOM"
    refute Prompt.base("CUSTOM", root) =~ "coding assistant"
  end

  test "compose_agent/2 appends a non-blank agent prompt" do
    assert Prompt.compose_agent("BASE", "AGENT") == "BASE\n\nAGENT"
  end

  test "compose_agent/2 leaves a blank agent prompt alone" do
    assert Prompt.compose_agent("BASE", "") == "BASE"
    assert Prompt.compose_agent("BASE", "   \n") == "BASE"
  end

  test "replace_in_context/2 replaces the system message in place" do
    context =
      ReqLLM.Context.new()
      |> ReqLLM.Context.append(ReqLLM.Context.system("OLD"))
      |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))

    replaced = Prompt.replace_in_context(context, "NEW")
    [system, user] = ReqLLM.Context.to_list(replaced)

    assert Enum.map_join(system.content, "", &(&1.text || "")) == "NEW"
    assert user.role == :user
  end

  test "replace_in_context/2 prepends a system message when there is none" do
    context = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))
    [system, _user] = ReqLLM.Context.to_list(Prompt.replace_in_context(context, "NEW"))
    assert system.role == :system
  end

  # -- ADR 024: per-model framework prompt --------------------------------

  describe "family/1" do
    test "maps model ids to a prompt family, defaulting unknown ones" do
      assert Prompt.family("anthropic:claude-sonnet-4-20250514") == "claude"
      assert Prompt.family("github_copilot:claude-3-5") == "claude"
      assert Prompt.family("ollama:qwen3:14b") == "default"
      assert Prompt.family("ollama_cloud:deepseek-v4.1-flash") == "default"
      assert Prompt.family(nil) == "default"
    end
  end

  describe "framework/1" do
    test "returns a real prompt, not the five-line stub, per family" do
      default = Prompt.framework("ollama:qwen3")
      claude = Prompt.framework("anthropic:claude-sonnet-4")

      assert String.length(default) > 500
      assert default != claude
    end

    test "the vendored text never impersonates opencode and names OUR tools" do
      for model <- ["ollama:qwen3", "anthropic:claude-sonnet-4"] do
        prompt = Prompt.framework(model)

        # identity is rewritten (THIRD_PARTY.md): no upstream branding
        refute prompt =~ "opencode"
        refute prompt =~ "OpenCode"
        # our canonical tool names, not opencode's (read/bash/write/...)
        assert prompt =~ "read_file"
        assert prompt =~ "write_file"
      end
    end

    test "both families carry the multi-step tracking rule (ADR 031 amendment)" do
      for model <- ["ollama:qwen3", "anthropic:claude-sonnet-4"] do
        prompt = Prompt.framework(model)

        assert prompt =~ "Tracking multi-step work"
        assert prompt =~ "use `todowrite`"
      end
    end

    test "an unknown family falls back to the default file" do
      assert Prompt.framework("ollama:qwen3") == Prompt.framework(nil)
    end
  end

  describe "base/3" do
    test "selects the framework prompt by model", %{root: root} do
      assert Prompt.base(nil, root, "anthropic:claude-sonnet-4") =~ "Professional objectivity"
      refute Prompt.base(nil, root, "ollama:qwen3") =~ "Professional objectivity"
    end

    test "an override still wins over the model file", %{root: root} do
      base = Prompt.base("CUSTOM", root, "anthropic:claude-sonnet-4")
      assert base =~ "CUSTOM"
      refute base =~ "Professional objectivity"
    end

    test "project memory is still appended for every model", %{root: root} do
      File.write!(Path.join(root, "AGENTS.md"), "PROJECT-RULE")
      assert Prompt.base(nil, root, "anthropic:claude-sonnet-4") =~ "PROJECT-RULE"
      assert Prompt.base(nil, root, "ollama:qwen3") =~ "PROJECT-RULE"
    end
  end

  # -- ADR 024: the per-call environment block ----------------------------

  describe "environment/2" do
    test "carries the model, cwd, git-repo flag, platform, date and harness", %{root: root} do
      block = Prompt.environment("ollama:test", root)

      assert block =~ "<env>"
      assert block =~ "Model: ollama:test"
      assert block =~ "Working directory: #{root}"
      assert block =~ "Is directory a git repo: no"
      assert block =~ "Platform: "
      assert block =~ "Today's date: #{Date.utc_today()}"
      assert block =~ "Harness: #{Prompt.harness()}"
    end

    test "names the software the model is running in, not only the machine" do
      # This repo is both the harness and the product, so the block has to
      # say something about the harness: a reviewing agent otherwise has to
      # infer that the thing it is inside is the thing it is reading.
      block = Prompt.environment("m", File.cwd!())

      assert block =~ ~r/^  Harness: \S.*$/m
      refute block =~ "Harness: unknown"
    end

    test "reports a git repo when .git is present", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git"))
      assert Prompt.environment("m", root) =~ "Is directory a git repo: yes"
    end

    test "a linked worktree names the branch from its gitdir pointer", %{root: root} do
      # .git is a FILE pointing at the main repo's worktrees/<name>; that
      # dir's HEAD names the branch. No `git` call — two file reads.
      gitdir = Path.join([root, "main", ".git", "worktrees", "wt"])
      File.mkdir_p!(gitdir)
      File.write!(Path.join(gitdir, "HEAD"), "ref: refs/heads/dev/mjansen\n")
      File.write!(Path.join(root, ".git"), "gitdir: #{gitdir}\n")

      block = Prompt.environment("m", root)
      assert block =~ "Git: linked worktree, dev/mjansen"
    end

    test "a plain checkout names its branch and no worktree", %{root: root} do
      gitdir = Path.join(root, ".git")
      File.mkdir_p!(gitdir)
      File.write!(Path.join(gitdir, "HEAD"), "ref: refs/heads/devel\n")

      block = Prompt.environment("m", root)
      assert block =~ "Git: branch devel"
      refute block =~ "linked worktree"
    end

    test "a detached HEAD shows the short hash, not a branch name", %{root: root} do
      gitdir = Path.join(root, ".git")
      File.mkdir_p!(gitdir)
      File.write!(Path.join(gitdir, "HEAD"), "65c2434deadbeef0123456789abcdef01234567\n")

      block = Prompt.environment("m", root)
      assert block =~ "Git: branch 65c2434"
    end

    test "a non-repo has no Git row at all", %{root: root} do
      refute Prompt.environment("m", root) =~ "Git:"
    end

    test "opts name the agent and the store" do
      block =
        Prompt.environment("m", "/tmp", agent: %{name: "plan"}, store: "/tmp/store.db")

      assert block =~ "Agent: plan"
      assert block =~ "Store: /tmp/store.db"
    end

    test "a subagent is marked as such, and a missing agent or store adds no row" do
      block = Prompt.environment("m", "/tmp", agent: %{name: "explore", mode: :subagent})
      assert block =~ "Agent: explore (subagent)"

      refute Prompt.environment("m", "/tmp") =~ "Agent:"
      refute Prompt.environment("m", "/tmp") =~ "Store:"
    end
  end

  describe "with_environment/3" do
    test "appends the block to the system message, leaving the stored context alone" do
      context =
        ReqLLM.Context.new()
        |> ReqLLM.Context.append(ReqLLM.Context.system("BASE"))
        |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))

      on_wire = Prompt.with_environment(context, "ollama:test", "/tmp")

      [%ReqLLM.Message{role: :system} = sys | _] = ReqLLM.Context.to_list(on_wire)
      text = Enum.map_join(sys.content, "", &(&1.text || ""))
      assert text =~ "BASE"
      assert text =~ "<env>"

      # the STORED context must not have gained the volatile block
      [%ReqLLM.Message{content: stored} | _] = ReqLLM.Context.to_list(context)
      refute Enum.map_join(stored, "", &(&1.text || "")) =~ "<env>"
      assert length(ReqLLM.Context.to_list(context)) == 2
    end

    test "is a no-op on a context with no system message" do
      context = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))
      assert Prompt.with_environment(context, "m", "/tmp") == context
    end
  end

  describe "todos_block/1" do
    test "one [status] line per item" do
      block = Prompt.todos_block([%{"content" => "Fix parser", "status" => "in_progress"}])
      assert block =~ "- [in_progress] Fix parser"
    end

    test "renders agent-private notes as an indented sub-line" do
      block =
        Prompt.todos_block([
          %{"content" => "Fix parser", "status" => "in_progress", "notes" => "a.ex:42\n13 fails"}
        ])

      assert block =~ "- [in_progress] Fix parser"
      assert block =~ "\n    a.ex:42"
      assert block =~ "\n    13 fails"
    end

    test "an item with no notes has no sub-line" do
      block = Prompt.todos_block([%{"content" => "A", "status" => "pending"}])
      refute block =~ "\n    "
    end

    test "the upkeep rule rides the block, and says to clear a finished list" do
      block = Prompt.todos_block([%{"content" => "A", "status" => "pending"}])

      # the ONE instruction the tool description has no home for; the other
      # rules ("mark done promptly") live in the description, so the block
      # does NOT repeat them (review N80)
      assert block =~ "send `[]`"
      assert block =~ "a stale plan misleads the human"
      refute block =~ "not in a batch at the end"
    end

    test "no list means no block at all, so a session that never plans gains no chrome" do
      assert Prompt.todos_block([]) == nil
    end
  end

  describe "with_capabilities/2" do
    test "a fully equipped read-write session with no ask-policy sends NO block" do
      assert Prompt.with_capabilities(base(), %{
               missing: [],
               shell_mode: :rw,
               gate: %{"git" => :allow, "shell" => :allow}
             }) == base()
    end

    test "no gate map at all keeps the earlier no-deficit behaviour" do
      assert Prompt.with_capabilities(base(), %{missing: [], shell_mode: :rw}) == base()
    end

    test "names the tools the session does not have" do
      text =
        Prompt.with_capabilities(base(), %{
          missing: ["edit", "write_file", "git"],
          shell_mode: :rw
        })
        |> system_text()

      assert text =~ "Session capabilities:"
      assert text =~ "edit, write_file, git"
      assert text =~ "unknown tool"
      refute text =~ "READ-ONLY"
    end

    test "a read-only shell is stated even when every tool is present" do
      text =
        Prompt.with_capabilities(base(), %{missing: [], shell_mode: :ro})
        |> system_text()

      assert text =~ "READ-ONLY"
      assert text =~ "read-only filesystem"
      refute text =~ "unknown tool"
    end

    test "both clauses combine into one block" do
      text =
        Prompt.with_capabilities(base(), %{missing: ["edit"], shell_mode: :ro})
        |> system_text()

      assert text =~ "edit"
      assert text =~ "READ-ONLY"
    end

    test "an ask-policy is stated with no deficit at all" do
      # the `gate` map comes from the gate's own decision path; a fully
      # equipped, read-write session can still have a tool that asks
      text =
        Prompt.with_capabilities(base(), %{
          missing: [],
          shell_mode: :rw,
          gate: %{"git" => :ask, "shell" => :allow}
        })
        |> system_text()

      assert text =~ "Session capabilities:"
      assert text =~ "git require the human's approval"
      # framed as a cost (one keystroke), NOT as a refusal or a reason to
      # avoid the call
      assert text =~ "not a refusal"
      assert text =~ "when the step is worth it"
      refute text =~ "unknown tool"
      refute text =~ "READ-ONLY"
    end

    test "the ask clause joins the deficit clauses" do
      text =
        Prompt.with_capabilities(base(), %{
          missing: ["edit", "write_file"],
          shell_mode: :ro,
          gate: %{"webfetch" => :ask}
        })
        |> system_text()

      assert text =~ "edit, write_file"
      assert text =~ "READ-ONLY"
      assert text =~ "webfetch require the human's approval"
    end

    test "no ask in the gate map means no block (nothing to say)" do
      assert Prompt.with_capabilities(base(), %{
               missing: [],
               shell_mode: :rw,
               gate: %{"git" => :allow, "shell" => :allow}
             }) == base()
    end

    test "is a no-op on a context with no system message" do
      context = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))

      assert Prompt.with_capabilities(context, %{missing: ["edit"], shell_mode: :ro}) == context
    end
  end

  describe "with_budget/2" do
    # The block is built from a %ContextBudget{} (ADR 040): every field is
    # required, so a producer that forgets one fails to compile instead of
    # silently dropping a clause. These tests therefore state the whole
    # value, and `budget/1` keeps the defaults of one realistic session
    # (500k window, 50% soft ratio, 64k reserve) in ONE place.
    defp budget(overrides) do
      struct!(
        ContextBudget,
        Keyword.merge(
          [
            used: 100_000,
            window: 500_000,
            soft: 250_000,
            hard: 436_000,
            warn_at: 200_000,
            rounds: 1,
            max_rounds: 200
          ],
          overrides
        )
      )
    end

    test "states the band, and no number at all" do
      text = Prompt.with_budget(base(), budget(used: 350_000)) |> system_text()

      # 350k of 436k hard: past the soft line, before the hard one
      assert text =~ "past the auto-summary line"
      refute text =~ "350k"
      refute text =~ "70%"
      refute text =~ "250k"
      refute text =~ "436k"
    end

    test "hints past the soft line, and says notes survive summarization" do
      text = Prompt.with_budget(base(), budget(used: 300_000)) |> system_text()

      assert text =~ "past the auto-summary line"
      assert text =~ "notes"
    end

    test "is calm (no hint) when there is room" do
      text = Prompt.with_budget(base(), budget(used: 100_000)) |> system_text()

      assert text =~ "there is room"
      refute text =~ "past the auto-summary line"
      refute text =~ "hard limit"
    end

    test "at the hard limit it says summarization is imminent" do
      text = Prompt.with_budget(base(), budget(used: 440_000)) |> system_text()

      assert text =~ "hard limit"
    end

    test "a non-budget argument is a no-op (the block is built, never guessed)" do
      assert Prompt.with_budget(base(), nil) == base()
      assert Prompt.with_budget(base(), %{used: 1, window: 500_000}) == base()
    end

    test "names the compact tool as a lever, calm and past the lines (ADR 040 OQ1)" do
      for used <- [100_000, 300_000, 440_000] do
        assert Prompt.with_budget(base(), budget(used: used)) |> system_text() =~ "`compact`"
      end

      # the calm line names the TOOL, so the verb exists before the wall
      calm = Prompt.with_budget(base(), budget(used: 100_000)) |> system_text()
      assert calm =~ "`compact` tool"
    end

    test "the tool-round budget is stated as a band, not as a counter" do
      # 54 of 200 is quiet …
      text = Prompt.with_budget(base(), budget(rounds: 54, max_rounds: 200)) |> system_text()
      refute text =~ "tool-round budget"

      # … 170 of 200 is not
      text = Prompt.with_budget(base(), budget(rounds: 170, max_rounds: 200)) |> system_text()
      assert text =~ "most of its tool-round budget"

      # … and the last round says the harness acts
      text = Prompt.with_budget(base(), budget(rounds: 200, max_rounds: 200)) |> system_text()
      assert text =~ "reached its tool-round budget"
    end

    test "no number reaches the prompt: the block is byte-stable across rounds" do
      # the whole point of the band (measured: 8 960/9 049 cached tokens
      # became 0 when one line of the first message changed)
      calm = Prompt.with_budget(base(), budget(used: 100_000, rounds: 3)) |> system_text()
      later = Prompt.with_budget(base(), budget(used: 149_000, rounds: 40)) |> system_text()

      assert calm == later
      refute calm =~ ~r/\d+k|\d+\.\d+M|\d+%/
    end

    test "the band is chosen by the limit, not by the window share" do
      # a 1M window at 120k used reads calm by percentage but is in the band
      in_band =
        Prompt.with_budget(
          base(),
          budget(used: 120_000, window: 1_048_576, soft: 140_000, hard: 150_000, warn_at: 112_000)
        )
        |> system_text()

      assert in_band =~ "approaching the soft line"
      refute in_band =~ "past the auto-summary line"
    end

    test "advises in the band between the approaching threshold and the soft line" do
      text = Prompt.with_budget(base(), budget(used: 210_000, warn_at: 200_000)) |> system_text()

      assert text =~ "approaching the soft line"
      assert text =~ "end your turn at a step boundary"
      assert text =~ "`compact`"
      # not the past-the-line wording: this is the calm side of the line
      refute text =~ "past the auto-summary line"
    end

    test "stays calm below the approaching threshold" do
      text = Prompt.with_budget(base(), budget(used: 100_000, warn_at: 200_000)) |> system_text()

      assert text =~ "there is room"
      refute text =~ "approaching the soft line"
      refute text =~ "past the auto-summary line"
      refute text =~ "hard limit"
    end
  end

  describe "ContextBudget.from_state/2" do
    test "reads every number from the state the decision and the sidebar use" do
      state = %State{
        id: "budget",
        context: ReqLLM.Context.new(),
        model: "ollama:test",
        status: :idle,
        context_window: 500_000,
        compaction_soft_limit: 250_000,
        compaction_hard_limit: 436_000,
        tool_rounds: 12,
        usage: %Usage{last_input_tokens: 210_000}
      }

      budget = ContextBudget.from_state(state, 200)

      assert %ContextBudget{
               used: 210_000,
               window: 500_000,
               soft: 250_000,
               hard: 436_000,
               warn_at: 200_000,
               rounds: 12,
               max_rounds: 200
             } = budget

      # `warn_at` comes from `Compactor.warn_threshold/1`, so the model's
      # advice and the human's note fire on the same number (ADR 029).
      assert budget.warn_at == Compactor.warn_threshold(state)
    end

    test "refuses a non-positive round budget (the guard always has a real one)" do
      state = %State{id: "budget", context: ReqLLM.Context.new(), model: "m", status: :idle}

      assert_raise FunctionClauseError, fn -> ContextBudget.from_state(state, 0) end
    end
  end
end
