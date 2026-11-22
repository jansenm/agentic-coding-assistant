# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.EscalationTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Tools.Escalation

  test "all/0 lists both escalations in schema order" do
    assert Escalation.all() == [:network, :change_vcs]
  end

  test "of/1 reads the keywords a tool's schema declares" do
    assert Escalation.of(network: [], change_vcs: [], reason: []) == [:network, :change_vcs]
    assert Escalation.of(network: [], reason: []) == [:network]
    assert Escalation.of(command: []) == []
    assert Escalation.of([]) == []
    assert Escalation.of(nil) == []
    assert Escalation.of("nope") == []
  end

  test "requested/2 reads the coarse booleans the agent states" do
    assert Escalation.requested(%{}) == []
    assert Escalation.requested(%{"network" => true}) == [:network]
    assert Escalation.requested(%{change_vcs: true}) == [:change_vcs]
    assert Escalation.requested(%{network: true, change_vcs: true}) == [:network, :change_vcs]
    assert Escalation.requested(%{"network" => "true"}) == [:network]
    assert Escalation.requested(%{"network" => 1}) == [:network]
    assert Escalation.requested(%{"network" => false}) == []
    assert Escalation.requested(%{"network" => nil}) == []
    assert Escalation.requested("nope") == []

    # the allowed list restricts what even counts
    assert Escalation.requested(%{network: true, change_vcs: true}, [:network]) == [:network]
    assert Escalation.requested(%{change_vcs: true}, [:network]) == []
  end

  test "requested?/2 only counts keywords the schema offers" do
    shell = [command: [], network: [], change_vcs: [], reason: []]
    git = [args: [], network: [], reason: []]

    assert Escalation.requested?(%{"network" => true}, shell)
    assert Escalation.requested?(%{"change_vcs" => true}, shell)
    refute Escalation.requested?(%{"change_vcs" => true}, git)
    refute Escalation.requested?(%{"command" => "git add"}, git)
    refute Escalation.requested?(%{"network" => true}, path: [])
    refute Escalation.requested?(%{"network" => true}, nil)
  end

  test "granted?/2 is the single-keyword reader a profile builder uses" do
    assert Escalation.granted?(%{"network" => true}, :network)
    refute Escalation.granted?(%{"network" => true}, :change_vcs)
    refute Escalation.granted?(%{}, :network)
    refute Escalation.granted?(nil, :network)
  end

  test "reason/1 trims, and only a non-empty string counts" do
    assert Escalation.reason(%{"reason" => "why"}) == "why"
    assert Escalation.reason(%{reason: " why "}) == "why"
    assert Escalation.reason(%{"reason" => "  "}) == nil
    assert Escalation.reason(%{"reason" => ""}) == nil
    assert Escalation.reason(%{"reason" => 42}) == nil
    assert Escalation.reason(%{}) == nil
    assert Escalation.reason("nope") == nil
  end

  test "verdict/2 requires a reason for a stated escalation" do
    assert Escalation.verdict(%{"command" => "echo hi"}) == :ok
    assert Escalation.verdict(%{"network" => true, "reason" => "why"}) == :ok

    assert {:error, msg} = Escalation.verdict(%{"network" => true})
    assert msg =~ "reason"
    assert msg =~ "network"
    assert {:error, _} = Escalation.verdict(%{"change_vcs" => true})

    # both stated, one reason: the message names both
    assert {:error, both} = Escalation.verdict(%{network: true, change_vcs: true})
    assert both =~ "network/change_vcs"

    # a tool that declares no escalation can never be asked for a reason
    assert Escalation.verdict(%{"network" => true}, []) == :ok
    assert Escalation.verdict(%{"network" => true}, [:change_vcs]) == :ok
  end
end
