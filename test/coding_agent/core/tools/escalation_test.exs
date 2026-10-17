defmodule CodingAgent.Core.Tools.EscalationTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Tools.Escalation

  test "all/0 lists both escalations in schema order" do
    assert Escalation.all() == [:network, :git_write]
  end

  test "of/1 reads the keywords a tool's schema declares" do
    assert Escalation.of(network: [], git_write: [], reason: []) == [:network, :git_write]
    assert Escalation.of(network: [], reason: []) == [:network]
    assert Escalation.of(command: []) == []
    assert Escalation.of([]) == []
    assert Escalation.of(nil) == []
    assert Escalation.of("nope") == []
  end

  test "requested/2 reads the coarse booleans the agent states" do
    assert Escalation.requested(%{}) == []
    assert Escalation.requested(%{"network" => true}) == [:network]
    assert Escalation.requested(%{git_write: true}) == [:git_write]
    assert Escalation.requested(%{network: true, git_write: true}) == [:network, :git_write]
    assert Escalation.requested(%{"network" => "true"}) == [:network]
    assert Escalation.requested(%{"network" => 1}) == [:network]
    assert Escalation.requested(%{"network" => false}) == []
    assert Escalation.requested(%{"network" => nil}) == []
    assert Escalation.requested("nope") == []

    # the allowed list restricts what even counts
    assert Escalation.requested(%{network: true, git_write: true}, [:network]) == [:network]
    assert Escalation.requested(%{git_write: true}, [:network]) == []
  end

  test "requested?/2 only counts keywords the schema offers" do
    shell = [command: [], network: [], git_write: [], reason: []]
    git = [args: [], network: [], reason: []]

    assert Escalation.requested?(%{"network" => true}, shell)
    assert Escalation.requested?(%{"git_write" => true}, shell)
    refute Escalation.requested?(%{"git_write" => true}, git)
    refute Escalation.requested?(%{"command" => "git add"}, git)
    refute Escalation.requested?(%{"network" => true}, path: [])
    refute Escalation.requested?(%{"network" => true}, nil)
  end

  test "granted?/2 is the single-keyword reader a profile builder uses" do
    assert Escalation.granted?(%{"network" => true}, :network)
    refute Escalation.granted?(%{"network" => true}, :git_write)
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
    assert {:error, _} = Escalation.verdict(%{"git_write" => true})

    # both stated, one reason: the message names both
    assert {:error, both} = Escalation.verdict(%{network: true, git_write: true})
    assert both =~ "network/git_write"

    # a tool that declares no escalation can never be asked for a reason
    assert Escalation.verdict(%{"network" => true}, []) == :ok
    assert Escalation.verdict(%{"network" => true}, [:git_write]) == :ok
  end
end
