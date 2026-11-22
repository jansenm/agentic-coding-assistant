# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.PoisonedContextTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodingAgent.Core.Session

  @tmp_root System.tmp_dir!() |> Path.join("poison-#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  defp start(id, opts) do
    {:ok, _} =
      CodingAgent.Core.Session.Supervisor.start_session(
        Keyword.merge([id: id, scope_root: @tmp_root, test_mode: true], opts)
      )
  end

  defp text_of(%ReqLLM.Message{content: c}) when is_binary(c), do: c

  defp text_of(%ReqLLM.Message{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %ReqLLM.Message.ContentPart{text: t} -> t || ""
      _ -> ""
    end)
  end

  defp all_valid?(state) do
    Enum.all?(ReqLLM.Context.to_list(state.context), &String.valid?(text_of(&1)))
  end

  describe "prevent: tool output is scrubbed before the context" do
    test "a shell result containing raw binary does not poison the context" do
      # a file with invalid UTF-8 bytes (0x83, 0xFF)
      File.write!(Path.join(@tmp_root, "raw.bin"), <<0x83, 0xFF, 0x00, "readable tail">>)

      start("poison-shell", [])

      # shell cat of the binary file; no confinement in tests, so the
      # call is :ask and parks — approve it
      capture_log(fn ->
        :ok =
          Session.debug_gate("poison-shell", [
            %{id: "s1", name: "shell", arguments: %{"command" => "cat raw.bin"}}
          ])
      end)

      {:ok, state} = Session.state("poison-shell")

      if state.status == :interrupted do
        {:ok, state} = Session.decide("poison-shell", [%{id: "s1", decision: :approve}])
        assert all_valid?(state), "the shell result poisoned the context"
      else
        assert all_valid?(state)
      end
    end
  end

  describe "cure: a restored context is healed" do
    test "an invalid byte in a persisted tool result is repaired on resume" do
      poisoned =
        ReqLLM.Context.new()
        |> ReqLLM.Context.append(ReqLLM.Context.system("sys"))
        |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))
        |> ReqLLM.Context.append(
          ReqLLM.Context.tool_result("shell", "t1", <<"out ", 0x83, 0xFF, " end">>)
        )

      refute match?(
               {:ok, _},
               Jason.encode(Enum.map(ReqLLM.Context.to_list(poisoned), &Map.from_struct/1))
             )

      start("poison-resume", context: poisoned)
      {:ok, state} = Session.state("poison-resume")

      assert all_valid?(state)

      assert {:ok, _} =
               Jason.encode(Enum.map(ReqLLM.Context.to_list(state.context), &Map.from_struct/1))
    end

    test "the readable parts of a poisoned message are preserved" do
      poisoned =
        ReqLLM.Context.new()
        |> ReqLLM.Context.append(ReqLLM.Context.system("sys"))
        |> ReqLLM.Context.append(
          ReqLLM.Context.tool_result("shell", "t1", <<"important output", 0x83, "done">>)
        )

      start("poison-preserve", context: poisoned)
      {:ok, state} = Session.state("poison-preserve")

      text =
        state.context
        |> ReqLLM.Context.to_list()
        |> Enum.find(&(&1.role == :tool))
        |> text_of()

      assert text =~ "important output"
      assert text =~ "done"
    end

    test "a clean context is left byte-identical (no needless rewrite)" do
      clean =
        ReqLLM.Context.new()
        |> ReqLLM.Context.append(ReqLLM.Context.system("sys"))
        |> ReqLLM.Context.append(ReqLLM.Context.user("hello"))

      start("poison-clean", context: clean)
      {:ok, state} = Session.state("poison-clean")

      assert Enum.map(ReqLLM.Context.to_list(state.context), &text_of/1) == ["sys", "hello"]
    end
  end
end
