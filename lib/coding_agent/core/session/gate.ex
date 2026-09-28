defmodule CodingAgent.Core.Session.Gate do
  @moduledoc """
  The permission checkpoint's decision logic (ADR 010 + 015), extracted
  from `Session`.

  Given a policy, a scope root and a round's tool calls, `classify/3`
  sorts every call into one of five buckets:

    * `:blacklisted` — a shell call whose leading program duplicates a
      native tool; denied with a steering message, no keystroke spent;
    * `:no_reason` — an escalation (`network`/`git_write`) without the
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
  own choice and always wins; an escalation (`network`/`git_write`)
  still asks, because it widens the profile the agent stated it needs.
  `Permissions` answers the pure-policy question (explicit entry, else a
  supplied fallback), and this module supplies the confinement fallback
  — so there is no second policy lookup implementation.
  """

  alias CodingAgent.Core.Permissions
  alias CodingAgent.Core.ToolCall
  alias CodingAgent.Core.Tools.Shell

  require Logger

  @typedoc "One call's classification buckets, in round order."
  @type plan :: %{
          blacklisted: [term()],
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
    {blacklisted, rest} =
      Enum.split_with(calls, fn call ->
        {_id, name, args} = ToolCall.normalize(call)
        name == "shell" and match?({:ok, _}, Shell.blacklisted?(args))
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
      blacklisted: blacklisted,
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
    rel_path = call_rel_path(scope_root, args)

    Permissions.effective(policy, tool, rel_path, fallback: fallback_for(tool, args))
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

  @doc "The result for a blacklisted (native-tool-duplicating) shell call."
  @spec blacklist_result(term()) :: map()
  def blacklist_result(call) do
    {id, _name, args} = ToolCall.normalize(call)
    {:ok, guidance} = Shell.blacklisted?(args)
    %{id: id, name: "shell", content: "error: #{guidance}"}
  end

  @doc "The result for an escalation whose required reason is missing."
  @spec no_reason_result(term()) :: map()
  def no_reason_result(call) do
    {id, _name, args} = ToolCall.normalize(call)
    {:error, guidance} = Shell.escalation_verdict(args)
    %{id: id, name: "shell", content: "error: #{guidance}"}
  end

  @doc "Whether an escalation was requested without the reason ADR 015 requires."
  @spec unanswerable_escalation?(String.t(), term()) :: boolean()
  def unanswerable_escalation?("shell", args) do
    match?({:error, _}, Shell.escalation_verdict(args))
  end

  def unanswerable_escalation?(_name, _args), do: false

  # The policy matches against the tool's path argument, relative to the
  # scope root. The gate consults the call's OWN arguments — this is the
  # security boundary, so the path always comes from the call itself.
  #
  # This is TEXTUAL (Path.expand, no filesystem); the tools resolve
  # PHYSICALLY (symlinks followed) via Containment. Net effect is safe:
  # an allow pattern can never be BYPASSED by a symlink, because
  # execution still rejects a physically-escaping path — but it means an
  # allow-pattern is not a capability. A "tmp/** = allow" pattern next
  # to a symlink tmp -> /etc matches the CALL and then fails at
  # execution with "path escapes the session scope".
  @doc false
  def call_rel_path(scope_root, args) when is_map(args) do
    path = Map.get(args, "path") || Map.get(args, :path)

    case path do
      p when is_binary(p) ->
        root = Path.expand(scope_root || File.cwd!())
        expanded = Path.expand(p, root)

        if String.starts_with?(expanded <> "/", root <> "/") do
          Path.relative_to(expanded, root)
        else
          # absolute path outside scope: policy matches the raw path; the
          # tool itself will reject execution anyway
          p
        end

      _ ->
        ""
    end
  end

  def call_rel_path(_scope_root, _args), do: ""

  # The confinement fallback (ADR 030). A session only exists when a
  # confining sandbox is active (`Session.init/1`), so `shell`/`git` are
  # allow-by-default here — with one exception: a stated escalation
  # (network / git_write) widens the profile and therefore re-enables the
  # prompt. An explicit policy entry always wins over this fallback
  # (`Permissions.effective/4`).
  defp fallback_for("shell", args) do
    if Shell.escalated?(args), do: :ask, else: :allow
  end

  # git always runs with `.git` writable inside the profile; no
  # escalations. A user who wants every git call reviewed writes
  # `[permissions.git] "*" = "ask"`.
  defp fallback_for("git", _args), do: :allow

  defp fallback_for(tool, _args), do: Permissions.default_for(tool)

  defp tool_name(name) when is_binary(name), do: name
  defp tool_name(other), do: to_string(other)

  defp log(_session_id, _id, :allow), do: :ok

  defp log(session_id, id, decision) do
    Logger.debug("gate: tool call #{inspect(id)} in session #{session_id} -> #{decision}")
  end
end
