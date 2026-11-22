# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.TestSandbox.Unavailable do
  @moduledoc """
  Test sandbox double: NOT available on this machine — the hardened-host
  case (no bwrap / disabled user namespaces). The resolver yields no usable
  implementation and `diagnose/0` must report a reason.
  """

  @behaviour CodingAgent.Core.Sandbox

  @impl true
  def id, do: :test_unavailable

  @impl true
  def available?, do: false

  @impl true
  def check, do: {:error, "test sandbox is unavailable"}

  @impl true
  def wrap(_spec, _profile), do: {:error, :unavailable}
end
