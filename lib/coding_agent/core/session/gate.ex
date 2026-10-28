defmodule CodingAgent.Core.Session.Gate do
  @moduledoc """
  The permission checkpoint's decision logic (ADR 010 + 015), extracted
  from `Session`.

  Given a policy, a scope root and a round's tool calls, `classify/3`
  sorts every call into one of five buckets:

    * `:redirected` — a shell call whose leading program is a PLAIN grep
      search (the one shape `Shell.redirect/1` covers since 2026-10-28);
      answered with a one-line hint, no keystroke spent;
    * `:no_reason` — an escalation (`network`/`change_vcs`) without the
      stated reason the human needs to answer the prompt (ADR 015);
    * `:denied` — an explicit policy `deny`; answered in the same round,
      never parked (approving a denied call would run a forbidden
      action);
    * `:auto` — `allow`: executed without a prompt;
    * `:pending` — `ask`: the session parks until `decide/2`.

  `decision/4` is the one production policy path. Since ADR 030 a
  session only exists under a confining sandbox, so `shell`/`git` are
  allow-by-default: the confinement fallback no longer depends on a
  runtime probe. An explicit `allow`/`ask`/`deny` entry is the user's
  own choice and always wins; an escalation (`network`/`change_vcs`)
  still asks, because it widens the profile the agent stated it needs.
  Which escalations a tool may state is read from that tool's own
  parameter schema (`Tools.Escalation`), not assumed here.
  `Permissions` answers the pure-policy question (explicit entry, else a
  supplied fallback), and this module supplies the confinement fallback
  — so there is no second policy lookup implementation.
  """

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.ToolCall
  alias CodingAgent.Core.Tools.Escalation
  alias CodingAgent.Core.Tools.Git
  alias CodingAgent.Core.Tools.Shell

  require Logger

  @typedoc "One call's classification buckets, in round order."
  @type plan :: %{
          redirected: [term()],
          no_reason: [term()],
          denied: [term()],
          auto: [term()],
          pending: [term()]
        }

  @doc """
  Classifies a round's calls into `t:plan/0` under `policy` and
  `scope_root`. `session_id` is used only for the debug decision log.
  """
  @spec classify(String.t(), Permissions.t(), String.t() | nil, [term()]) :: plan()
  def classify(session_id, policy, scope_root, calls) do
    {redirected, rest} =
      Enum.split_with(calls, fn call ->
        {_id, name, args} = ToolCall.normalize(call)
        name == "shell" and match?({:hint, _}, Shell.redirect(args))
      end)

    {auto, pending, denied, no_reason} =
      Enum.reduce(rest, {[], [], [], []}, fn call, {auto, pending, denied, no_reason} ->
        {id, name, args} = ToolCall.normalize(call)

        decision = decision(policy, scope_root, name, args)
        log(session_id, id, decision)

        case {decision, unanswerable_escalation?(name, args)} do
          {:allow, _} -> {[call | auto], pending, denied, no_reason}
          {:ask, true} -> {auto, pending, denied, [call | no_reason]}
          {:ask, false} -> {auto, [call | pending], denied, no_reason}
          {:deny, _} -> {auto, pending, [call | denied], no_reason}
        end
      end)

    %{
      redirected: redirected,
      no_reason: Enum.reverse(no_reason),
      denied: Enum.reverse(denied),
      auto: Enum.reverse(auto),
      pending: Enum.reverse(pending)
    }
  end

  @doc """
  The gate decision for one call. Delegates the policy lookup to
  `Permissions.effective/4`, supplying the confinement fallback for the
  no-explicit-entry case (ADR 015/030).
  """
  @spec decision(Permissions.t(), String.t() | nil, String.t(), term()) :: Permissions.decision()
  def decision(policy, scope_root, name, args) do
    tool = tool_name(name)
    fallback = fallback_for(tool, args)

    # A call may name more than one path (move_file: `from` and `to`).
    # Every one is evaluated and the MOST RESTRICTIVE wins — otherwise a
    # `[permissions.move_file] "lib/**" = "deny"` would not match (the
    # lookup reads only `path`) and the fallback would allow the call.
    scope_root
    |> call_rel_paths(args)
    |> Enum.map(&Permissions.effective(policy, tool, &1, fallback: fallback))
    |> Enum.reduce(&Permissions.most_restrictive/2)
  end

  @doc "The result for an explicit-policy-denied call."
  @spec denied_result(term()) :: map()
  def denied_result(call) do
    {id, name, _} = ToolCall.normalize(call)

    %{
      id: id,
      name: name,
      content: "error: permission denied by policy; the user did not approve this action"
    }
  end

  @doc "The result for a redirected (native-tool-duplicating) shell call."
  @spec redirect_result(term()) :: map()
  def redirect_result(call) do
    {id, _name, args} = ToolCall.normalize(call)
    {:hint, hint} = Shell.redirect(args)
    %{id: id, name: "shell", content: "error: #{hint}"}
  end

  @doc "The result for an escalation whose required reason is missing."
  @spec no_reason_result(term()) :: map()
  def no_reason_result(call) do
    {id, name, args} = ToolCall.normalize(call)
    {:error, guidance} = Escalation.verdict(args, escalation_names(name))
    %{id: id, name: name, content: "error: #{guidance}"}
  end

  @doc "Whether a call stated an escalation it cannot be asked about, having no reason."
  @spec unanswerable_escalation?(String.t(), term()) :: boolean()
  def unanswerable_escalation?(name, args) do
    match?({:error, _}, Escalation.verdict(args, escalation_names(name)))
  end

  # The escalation keywords a tool actually declares, read from the tool
  # that will run — a keyword a tool does not offer is not an escalation,
  # and asking for one must not be able to widen a profile that has no such
  # grant. Tools with no escalations (every file tool) get the empty list,
  # so `verdict/2` can never demand a reason for them.
  defp escalation_names("shell"), do: Escalation.of(Shell.parameter_schema())
  defp escalation_names("git"), do: Escalation.of(Git.parameter_schema())
  defp escalation_names(_name), do: []

  # The path argument(s) a call exposes to the policy, relative to the
  # scope root. Most calls name one (`path`); `move_file` names two
  # (`from`, `to`) and both must reach the policy. A call with no path
  # yields `[""]`, so the lookup stays exactly as it was for every other
  # tool.
  #
  # The matching is TEXTUAL (Path.expand, no filesystem); the tools
  # resolve PHYSICALLY (symlinks followed) via Containment. Net effect is
  # safe: an allow pattern can never be BYPASSED by a symlink, because
  # execution still rejects a physically-escaping path — but it means an
  # allow-pattern is not a capability. A "tmp/** = allow" pattern next
  # to a symlink tmp -> /etc matches the CALL and then fails at
  # execution with "path escapes the session scope".
  @doc false
  def call_rel_paths(scope_root, args) when is_map(args) do
    [arg_path(args, "path"), arg_path(args, "from"), arg_path(args, "to")]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&rel_path(scope_root, &1))
    |> case do
      [] -> [""]
      paths -> Enum.uniq(paths)
    end
  end

  def call_rel_paths(_scope_root, _args), do: [""]

  defp arg_path(args, key), do: Map.get(args, key) || Map.get(args, String.to_atom(key))

  defp rel_path(scope_root, path) do
    root = Path.expand(scope_root || File.cwd!())
    expanded = Path.expand(path, root)

    if String.starts_with?(expanded <> "/", root <> "/") do
      Path.relative_to(expanded, root)
    else
      # absolute path outside scope: policy matches the raw path; the
      # tool itself will reject execution anyway
      path
    end
  end

  # The confinement fallback (ADR 030). A session only exists when a
  # confining sandbox is active (`Session.init/1`), so every tool is
  # allow-by-default here — with one exception: a stated escalation
  # (network / change_vcs) widens the profile and therefore re-enables the
  # prompt. An explicit policy entry always wins over this fallback
  # (`Permissions.effective/4`).
  defp fallback_for("shell", args) do
    if Shell.escalated?(args), do: :ask, else: :allow
  end

  # git grants `change_vcs` unconditionally (ADR 015 decision 4), so the
  # only escalation left to ask about is the network one (`fetch`/`clone`).
  defp fallback_for("git", args) do
    if Escalation.requested?(args, Git.parameter_schema()), do: :ask, else: :allow
  end

  defp fallback_for(tool, _args), do: Permissions.default_for(tool)

  defp tool_name(name) when is_binary(name), do: name
  defp tool_name(other), do: to_string(other)

  defp log(_session_id, _id, :allow), do: :ok

  defp log(session_id, id, decision) do
    Logger.debug("gate: tool call #{inspect(id)} in session #{session_id} -> #{decision}")
  end
end
