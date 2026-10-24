defmodule CodingAgent.Core.Session.Supervisor do
  @moduledoc """
  Starts sessions on demand under the application supervisor.

  ## A session is never restarted (review N86, ADR 047)

  The child spec is `restart: :temporary`. A session is started *from
  arguments* — `%{id: id, start: {Session, :start_link, [opts]}}` — and
  OTP restarts a child from that same spec. Under `restart: :transient`
  an abnormal exit therefore brought the process back holding the ORIGINAL
  start options (`Context.new()`, the configured model, the start-time
  agent) while the conversation and the last saved state were gone from
  the live process.

  The measured cost was not "a stale transcript read": the next turn
  boundary wrote the impostor's init snapshot OVER the persisted
  conversation. From `MIX_ENV=test mix run --no-start`, both policies on
  the same seed (one model switch, seven messages on disk):

      :transient   after kill: LIVE model=start-model messages=1
                   after one boundary: store has messages=1     <- clobbered
      :temporary   after kill: {:error, :not_found}
                   store has messages=7, model=switched-model   <- intact

  A smarter start spec (load the store, then restart) would keep the data,
  and is still the wrong shape: it would rebuild a *session* from a
  snapshot under the same id — conversation rolled back to the last
  boundary, in-flight turn gone, the driver's view still showing both —
  and nobody is told. A driver that knows how to resume a persisted
  session already exists (`Session.resume/2`, the picker's path); recovery
  is a verb a caller chooses, not a supervision side effect.

  With `:temporary` the crash IS the outcome: the registry entry goes
  away, every `safe_call` degrades to `{:error, :not_found}`, and the
  store keeps exactly what the last boundary wrote. A `:normal` stop (the
  subagent seam retiring a finished child) was already not restarted, so
  no caller loses anything.

  ## The blast radius

  `:transient` also carried a supervisor-level hazard that `:temporary`
  removes outright. A `DynamicSupervisor` applies OTP's default intensity
  (`max_restarts: 3`, `max_seconds: 5`) to its children as a GROUP, so
  four crashes of ONE session within five seconds took the whole session
  supervisor down — and with it every other live session. Measured against
  the app's own supervisor: after the fourth kill it exited `:shutdown`
  and the parent rebuilt it empty, with an unrelated session dead.
  A policy that cannot restart a child cannot exhaust that budget.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Starts a session with the given options; idempotent per session id."
  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    id = Keyword.fetch!(opts, :id)

    child = %{
      id: id,
      start: {CodingAgent.Core.Session, :start_link, [opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
