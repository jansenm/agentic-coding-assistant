# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.Shell do
  @default_timeout 300
  @min_timeout 1
  @max_timeout 1800

  @moduledoc """
  Shell execution tool (slice 2c). Under ADR 015 the command runs inside a
  sandbox (`CodingAgent.Core.Sandbox`); a confining sandbox is always
  active (ADR 030), so it is allow-by-default *inside the profile*,
  because its worst-case effect is bounded by construction rather than
  guessed from command text.

  Two coarse **escalations** re-enable the prompt even under confinement,
  and the agent must *state* them — they are never inferred from the
  command text (ADR 015):

    * `network: true` — may this call use the network (default false);
    * `change_vcs: true` — may this call change the repository's version
      control state, i.e. the git index, objects and refs (default
      false; for scripts that must run git themselves).

  A git command that writes its repository state (`add`, `commit`, `tag`,
  `reset`, `stash`, …) fails under the default profile with
  `index.lock: Read-only file system` — the git metadata the command
  writes is bound read-only, which for a linked worktree is the MAIN
  repository's `.git` outside the scope root. The `git` tool runs with
  that grant already; `shell` needs it stated.

  The gate surfaces the requested timeout at the soft cap
  (#{@default_timeout}s) so the user can edit it before approval; the
  hard cap (#{@max_timeout}s) refuses longer runs and tells the model to
  split the work.

  Command redirects (2026-09-15 amendment 2, narrowed 2026-10-28): the
  gate's real cost was *y-fatigue* — most gated calls were grep-style read
  duplicates of native tools. So the gate consults one rule before the
  policy: a shell call whose leading program is a PLAIN grep search is
  answered with a one-line hint ("please use the grep tool") instead of a
  keystroke. Nothing else is redirected — a composed command (`|`, `&&`,
  a redirection) is the case where shell was the right call. Under
  confinement this is UX steering only, never a boundary — the mount
  bounds the call, not the command text.

  Output: stdout+stderr combined (merged through /bin/sh), exit code,
  wall time. On truncation head and tail are kept (tail matters for test
  summaries). On timeout the process is killed, and whatever output was
  captured so far is returned together with a timeout note.
  """

  alias CodingAgent.Core.Exec
  alias CodingAgent.Core.Tools
  alias CodingAgent.Core.Tools.Escalation

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "shell",
      description:
        "Run a shell command in the session scope root (through /bin/sh). " <>
          "Captures stdout and stderr, and reports the exit code. Give long " <>
          "commands a suitable timeout_secs (seconds); the hard cap is " <>
          "#{@max_timeout}s — split longer work into several commands. " <>
          "The command runs confined (filesystem limited to the scope and " <>
          "configured caches, no network). Git commands that change the " <>
          "repository (add, commit, tag, reset) fail with `index.lock: " <>
          "Read-only file system` unless you request change_vcs; the git " <>
          "tool already has that grant. These escalations require approval.",
      parameter_schema: parameter_schema(),
      callback: fn args -> execute(scope, args) end
    )
  end

  @doc """
  The tool's parameter schema. Public so the gate reads the SAME keywords
  the tool declares instead of assuming what a shell call may escalate.
  """
  @spec parameter_schema() :: keyword()
  def parameter_schema do
    [
      command: [type: :string, required: true, doc: "The shell command to run"],
      timeout_secs: [
        type: :integer,
        required: false,
        doc: "Maximum runtime in seconds (default #{@default_timeout}, max #{@max_timeout})"
      ],
      network: [
        type: :boolean,
        required: false,
        doc: "Escalation: allow network access for this call (default false)"
      ],
      change_vcs: [
        type: :boolean,
        required: false,
        doc:
          "Escalation: let this call change the repository's version control state — " <>
            "the git index, objects and refs, so `add`/`commit`/`tag`/`reset` work " <>
            "(default false). Prefer the git tool, which always has it"
      ],
      reason: [
        type: :string,
        required: false,
        doc:
          "REQUIRED when you set network or change_vcs: one short sentence, " <>
            "shown to the human in the approval prompt, explaining why this " <>
            "call needs the escalation. A request without a reason is refused."
      ]
    ]
  end

  @doc """
  The timeout is actually used for an execution, after clamping.
  Used by the gate (soft-cap decision) and tests.
  """
  @spec effective_timeout(term()) :: {:ok, pos_integer()} | {:error, String.t()}
  def effective_timeout(args) when is_map(args) do
    raw = Map.get(args, :timeout_secs) || Map.get(args, "timeout_secs") || @default_timeout

    case coerce(raw) do
      {:ok, secs} when secs > @max_timeout ->
        {:error,
         "timeout_secs #{secs} exceeds the hard cap of #{@max_timeout}s; " <>
           "split the work into several commands"}

      {:ok, secs} when secs < @min_timeout ->
        {:ok, @min_timeout}

      {:ok, secs} ->
        {:ok, secs}

      :error ->
        {:error, "timeout_secs must be an integer number of seconds"}
    end
  end

  def effective_timeout(_args), do: {:ok, @default_timeout}

  @doc "The soft cap: requested timeouts above this are flagged at the gate."
  def soft_cap, do: @default_timeout

  @doc """
  The escalations a `shell` call states (ADR 015): `:network` and
  `:change_vcs`, as coarse booleans the agent says. See
  `CodingAgent.Core.Tools.Escalation`, which owns the semantics; `shell`
  declares both keywords, so every escalation applies to it.
  """
  @spec escalations(term()) :: [Escalation.name()]
  def escalations(args), do: Escalation.requested(args)

  @doc "Whether a `shell` call asks to widen its profile at all."
  @spec escalated?(term()) :: boolean()
  def escalated?(args), do: escalations(args) != []

  @doc "The agent's stated reason for an escalation, or `nil`."
  @spec reason(term()) :: String.t() | nil
  defdelegate reason(args), to: Escalation

  @doc "The escalation gate verdict: `:ok`, or `{:error, guidance}` when a stated escalation has no reason."
  @spec escalation_verdict(term()) :: :ok | {:error, String.t()}
  defdelegate escalation_verdict(args), to: Escalation, as: :verdict

  @doc """
  Builds the sandbox profile for a call from the scope and the
  escalations the agent requested. Public so the gate and tests share one
  source of truth. `scope` may carry the mount schema (`:mounts`); absent
  or nil mounts add nothing.
  """
  @spec profile(map() | String.t(), term()) :: CodingAgent.Core.Sandbox.profile()
  def profile(scope, args) do
    {root, mounts, shell_mode} =
      case scope do
        %{root: root} = s ->
          {root, Map.get(s, :mounts) || CodingAgent.Core.Sandbox.Mounts.empty(),
           Map.get(s, :shell_mode, :rw)}

        root when is_binary(root) ->
          {root, CodingAgent.Core.Sandbox.Mounts.empty(), :rw}
      end

    %{
      root: root,
      network: Escalation.granted?(args, :network),
      change_vcs: Escalation.granted?(args, :change_vcs),
      # a read-only agent's shell cannot write the source either; an
      # unconfined sandbox refuses this rather than running read-write
      root_ro: shell_mode == :ro,
      session_id: session_id(scope),
      scratch: scratch(scope),
      rw: Map.get(mounts, :rw, []),
      ro: Map.get(mounts, :ro, []),
      hide: Map.get(mounts, :hide, [])
    }
  end

  defp session_id(%{} = scope), do: Map.get(scope, :session_id)
  defp session_id(_root), do: nil

  # The session scratch (ADR 022): nil for a bare root scope, so the
  # sandbox keeps its ephemeral tmpfs `/tmp`.
  defp scratch(%{} = scope), do: CodingAgent.Core.Session.Scratch.from_scope(scope)
  defp scratch(_root), do: nil

  # -- Execution --------------------------------------------------------------

  defp execute(scope, args) do
    command = Map.get(args, :command) || Map.get(args, "command")

    cond do
      not is_binary(command) or command == "" ->
        Tools.error("command must be a non-empty string")

      true ->
        with {:ok, secs} <- effective_timeout(args) do
          run(scope, command, Path.expand(scope.root), secs, args)
        end
    end
  end

  # -- The one redirect: a PLAIN grep search (2026-09-15 amendment 2, narrowed
  # 2026-10-28) ----------------------------------------------------------------
  #
  # Not "these commands are safe" — nothing here decides that; the sandbox
  # profile does — but "this shell spelling is strictly worse than the tool".
  # Exactly one case qualifies: a PLAIN grep search. The native tool caps the
  # match list, NAMES the files a walk skipped, spills the full list to a file
  # and reports "no matches" as a sentence instead of exit 1. `grep -rn foo lib`
  # gets none of that and the tool never costs more.
  #
  # The seven-row table this replaced was narrowed to one row because of what it
  # cost, measured on this repo's own store on 2026-10-28 (8 sessions, 519
  # display rows, 161 shell calls): it fired TWICE, and both firings were on a
  # COMPOSED command — `grep … | head`, `grep … $(…)` — where shell was the right
  # call, because the derivation is what keeps the context small. Both were
  # false positives, and the replay of that corpus shows why the cd-prefix
  # extension below was wrong too: it took the matcher from 1/161 to 79/161.
  #
  # The git row went with it, from measurement rather than taste: it never fired
  # on a git call (all 33 git-through-shell rows were `cd … && git …`), and a git
  # WRITE that hits the read-only `.git` is already explained in the result it
  # fails with — through real bwrap, `git commit` prints "fatal: Unable to create
  # '…/.git/index.lock': Read-only file system" and `Shell.note/2` appends the
  # cause naming BOTH the git tool and `change_vcs: true` plus a reason. Same one
  # round either way, and the note cannot fire on a call that would have worked.
  # The timeout row was a parameter both tools already document.
  #
  # So the load-bearing half of the rule is the second condition: a COMPOSED
  # command is never hinted. `grep -rn foo lib | head -40` answers with 40 lines
  # instead of 200, and the tools have no pipeline, so a hint there would steer
  # the caller away from the better call. That is the END of the list (owner
  # ruling 2026-10-28): enumerating every spelling an agent could use is an arms
  # race the table cannot win, and does not need to — the scope root is read-only
  # unless write access is granted, so the hint exists to save a round, not to
  # bound anything.
  #
  # The hint is ADVICE, never a wall (owner ruling 2026-10-13): a call that STATES
  # an escalation (`network: true` / `change_vcs: true`, each with its `reason`)
  # is asking to run this command as written by hand and goes to the gate like
  # any other escalated call — no hint.
  @grep_programs ~w(grep rg ag ack sg)

  @grep_hint "please use the grep tool instead of a shell search " <>
               "(it is allow-by-policy and returns capped, line-numbered matches)"

  @doc """
  The redirect verdict for a shell call's arguments: `{:hint, guidance}` for a PLAIN
  grep-family search (the value is the hint for the model), `:ok` otherwise.

  `:ok` is not "this command is safe" — nothing here decides that; the sandbox profile does.
  It means only "nothing to redirect you to". The first return is a hint, not a result, which
  is why it is tagged instead of being a bare `{:ok, message}` next to `:error`.

  Two conditions, both in `plain_grep?/1`: the FIRST program word is one of `#{inspect(@grep_programs)}`
  (basename of an absolute path, after env-var assignments — `FOO=1 grep …`), and the command is
  not composed (`|`, `&&`, `;`, a redirection, `$(…)`, a backtick). The comment above explains why
  the second one is load-bearing and why everything else left the table.
  """
  @spec redirect(term()) :: :ok | {:hint, String.t()}
  def redirect(args) when is_map(args) do
    if escalated?(args), do: :ok, else: hint_for(args)
  end

  def redirect(_args), do: :ok

  defp hint_for(args) do
    command = Map.get(args, :command) || Map.get(args, "command")
    if plain_grep?(command), do: {:hint, @grep_hint}, else: :ok
  end

  defp plain_grep?(command) when is_binary(command) do
    with false <- composed?(command),
         {:ok, prog} <- leading_program(command) do
      prog in @grep_programs
    else
      _ -> false
    end
  end

  defp plain_grep?(_command), do: false

  # Deliberately blunt: every operator that turns one command into several, and
  # every redirection, counts — `grep -rn foo lib 2>&1` and `grep foo > out` are
  # composed too. The lookarounds only keep ordinary code patterns (`=>`, `->`)
  # out; a search for `<div>` is read as a redirection, which errs toward RUNNING
  # the call, and that is the direction this table may err in.
  defp composed?(command) do
    Regex.match?(~r/[|;`]|&&|\$\(|(?<![-=<])>(?![=>])|<(?![=<])/, command)
  end

  defp leading_program(command) when is_binary(command) do
    command
    |> String.trim_leading()
    |> String.split(~r/\s+/)
    |> Enum.drop_while(fn token ->
      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, token)
    end)
    |> case do
      [] -> :error
      [prog | _rest] -> {:ok, Path.basename(prog)}
    end
  end

  defp run(scope, command, cwd, secs, args) do
    started = System.monotonic_time(:millisecond)
    profile = profile(scope, args)

    case Exec.run({:shell, command}, cwd, secs, profile, env: Exec.agent_env(), label: "shell") do
      {:ok, output, status} ->
        elapsed = System.monotonic_time(:millisecond) - started

        {:ok,
         Exec.format(command, output, {:exit, status}, elapsed, secs) <>
           note(profile, output)}

      {:timeout, partial} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, Exec.format(command, partial, :timeout, elapsed, secs)}

      {:stopped, partial} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, Exec.format(command, partial, :stopped, elapsed, secs)}

      {:error, reason} ->
        Tools.error("cannot run #{inspect(command)}: #{:file.format_error(reason)}")

      {:sandbox_error, reason} ->
        Tools.error("cannot confine #{inspect(command)}: #{inspect(reason)}")
    end
  end

  @doc """
  The note appended to a shell result whose output reports a write on a
  read-only path (review P5, fourth path); `""` for any other output.

  `Read-only file system` is ONE kernel string, so recognising it is not a
  parse of a program's error messages and not a list of the ways git can
  fail; what the note then says is a fact of the PROFILE the call ran with
  — the binds it actually had.

  Public so the branches can be asserted against a profile without a live
  bwrap; the integration test covers the round trip.
  """
  @spec note(CodingAgent.Core.Sandbox.profile(), String.t()) :: String.t()
  def note(profile, output) do
    if String.contains?(output, "Read-only file system") do
      "\nnote: a write hit a read-only path. " <> cause(profile)
    else
      ""
    end
  end

  # One clause, because the facts nest: `root_ro` is a POLICY that no flag
  # lifts (the narrower grant wins, so `change_vcs` cannot re-open what a
  # read-only agent closed), and it makes even the scope root unwritable —
  # a note telling such an agent to reach for a flag would send it after a
  # lever it does not have, and calling the root "writable" would be false.
  defp cause(profile) do
    cond do
      Map.get(profile, :root_ro, false) ->
        "This agent's scope root is bound read-only (shell_mode: :ro) — a policy, not " <>
          "a missing flag, so no tool can write here."

      Map.get(profile, :change_vcs, false) ->
        writable_roots() <> outside()

      true ->
        writable_roots() <>
          "This call ran without change_vcs, so the repository's git state (index, " <>
          "objects, refs) was read-only too — if that is what failed, use the git " <>
          "tool (it always has the grant) or change_vcs: true with a reason." <>
          outside()
    end
  end

  defp writable_roots,
    do: "Only the scope root and the configured cache mounts are writable. "

  # Said unconditionally, because it is true of every profile: no grant in
  # the mount table widens the filesystem (review N115). Without it the note
  # offers `change_vcs` for a path outside the scope root — measured by
  # deleting a file in the OTHER worktree, which no tool can write.
  defp outside,
    do:
      "A path outside them is not writable by any grant — change_vcs widens the " <>
        "repository's git state, not the filesystem."

  defp coerce(secs) when is_integer(secs), do: {:ok, secs}
  defp coerce(secs) when is_float(secs), do: {:ok, trunc(secs)}

  defp coerce(secs) when is_binary(secs) do
    case Integer.parse(secs) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp coerce(_), do: :error
end
