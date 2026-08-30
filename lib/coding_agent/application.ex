defmodule CodingAgent.Application do
  @moduledoc """
  OTP application for the coding agent.

  Supervision tree per ADR 003/008: today only the process registry the
  session layer will use; the session supervisor joins in phase 1 work.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: CodingAgent.Registry},
      {Registry, keys: :duplicate, name: CodingAgent.EventRegistry, partitions: System.schedulers_online()},
      CodingAgent.Core.Session.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CodingAgent.Supervisor)
  end
end