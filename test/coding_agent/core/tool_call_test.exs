# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.ToolCallTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.ToolCall

  test "normalizes a ReqLLM.ToolCall struct, decoding its JSON arguments" do
    call = %ReqLLM.ToolCall{
      id: "c1",
      type: "function",
      function: %{name: "shell", arguments: ~s({"command":"ls"})}
    }

    assert {"c1", "shell", %{"command" => "ls"}} = ToolCall.normalize(call)
  end

  test "normalizes a stream-event map with decoded arguments" do
    assert {"c2", "read_file", %{"path" => "a"}} =
             ToolCall.normalize(%{id: "c2", name: "read_file", arguments: %{"path" => "a"}})
  end

  test "normalizes a map with string arguments" do
    assert {"c3", "grep", %{"pattern" => "x"}} =
             ToolCall.normalize(%{id: "c3", name: "grep", arguments: ~s({"pattern":"x"})})
  end

  test "a map without arguments yields an empty map" do
    assert {"c4", "glob", %{}} = ToolCall.normalize(%{id: "c4", name: "glob"})
  end

  test "malformed JSON becomes an empty map, never a crash" do
    assert {"c5", "shell", %{}} =
             ToolCall.normalize(%{id: "c5", name: "shell", arguments: "{not json"})
  end

  test "decode/1 passes maps through and rejects non-maps" do
    assert %{"a" => 1} = ToolCall.decode(%{"a" => 1})
    assert %{} = ToolCall.decode("nope")
    assert %{} = ToolCall.decode(nil)
    assert %{} = ToolCall.decode(42)
    # valid JSON that is not an object is still not a usable argument map
    assert %{} = ToolCall.decode("[1,2]")
  end
end
