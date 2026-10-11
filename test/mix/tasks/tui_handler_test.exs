defmodule Mix.Tasks.TuiHandlerTest do
  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.Server
  alias Mix.Tasks.Tui
  alias Mix.Tasks.Tui.Handler

  # The TUI's log file is the ONLY record once the app owns the screen
  # (`:logger.remove_handler(:default)`), so this handler has three jobs:
  # render a message as TEXT, keep one physical line per event, and never
  # raise. The last one is not politeness — OTP REMOVES a raising handler
  # (`removed_failing_handler`), after which a running TUI logs nowhere.
  #
  # The context key is `:log_file`, NOT `:file`: ExUnit reserves `:file` and
  # refuses a setup that sets it.

  setup do
    dir = Path.join(System.tmp_dir!(), "tui-handler-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log_file = Path.join(dir, "tui.log")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{log_file: log_file}
  end

  defp write(log_file, msg, level \\ :warning) do
    File.rm(log_file)
    :ok = Handler.log(%{level: level, msg: msg}, %{config: %{file: log_file}})
    log_file |> File.read!() |> String.split("\n", trim: true)
  end

  test "a binary with a multibyte char is text, not a byte list", %{log_file: file} do
    # The bug this pins: OTP hands `{:string, binary}`, never a bare binary,
    # so the old `is_binary/1` branch was dead and `~p` rendered the message.
    # `~p` prints a binary as text only while every byte is printable-latin1;
    # the em dash (226,128,148) has continuation bits, so the context warning
    # — the one a user most needs to READ — became 19 lines of
    # comma-separated numbers in tui.log.
    #
    # Built the way `Session.maybe_warn_unverified_window/3` builds it.
    model = "ollama_cloud:deepseek-v4.1-flash"

    msg =
      "context window for #{model} is unknown to the model " <>
        "catalog; assuming 500k tokens. If the model's real window is " <>
        "smaller, set `context_window` in config.toml — otherwise compaction fires too " <>
        "late to be useful."

    [line] = write(file, {:string, msg})

    assert line =~ msg
    refute line =~ "226,128,148"
    assert String.valid?(line)
  end

  test "each msg shape OTP produces lands as one readable line", %{log_file: file} do
    assert [l1] = write(file, {:string, "plain ascii"})
    assert l1 =~ "[warning] plain ascii"

    # Logger.warning(["a ", "b"]) — chardata
    assert [l2] = write(file, {:string, ["chardata ", "list ", "—"]})
    assert l2 =~ "chardata list —"

    # :logger.warning(~c"…") — an Erlang charlist
    assert [l3] = write(file, {:string, ~c"erlang charlist"})
    assert l3 =~ "erlang charlist"

    # :logger.warning("fmt ~ts", [args]) — a format tuple, not {:string, _}
    assert [l4] = write(file, {~c"fmt — ~ts", ["中"]})
    assert l4 =~ "fmt — 中"

    assert [l5] = write(file, {:report, %{b: "grüße"}})
    assert l5 =~ "grüße"
  end

  test "one physical line per event, whatever the message contains", %{log_file: file} do
    # The old comment promised this and `~p` broke it twice: it wraps at a
    # fixed column, and it passes a newline in the message straight through.
    # 99 % of the live tui.log's 104k lines were wrapped `{:report, …}` dumps.
    [line] = write(file, {:string, "first\nsecond\rthird"})

    assert line =~ "first\\nsecond\\rthird"
    refute line =~ "\n"

    # a report does not wrap either, however big
    report = Map.new(1..40, fn i -> {:"key#{i}", "value #{i} with some text"} end)
    [report_line] = write(file, {:report, report})

    assert report_line =~ "key40"
    assert byte_size(report_line) > 120
  end

  test "an invalid UTF-8 binary is reported, never dropped and never raised", %{log_file: file} do
    [line] = write(file, {:string, <<0xFF, 0xFE, "broken">>})

    assert line =~ "[warning]"
    assert line =~ "255"
    assert String.valid?(line)
  end

  test "a malformed format string does not cost the event", %{log_file: file} do
    # `:io_lib.format/2` raises on a bad directive; the event must still land.
    [line] = write(file, {"format ~q that Elixir rejects", []})

    assert line =~ "[warning]"
    assert line =~ "format ~q"
  end

  test "an unwritable file is swallowed: OTP removes a raising handler", %{log_file: file} do
    # Not politeness: `:logger` removes a handler whose callback raises, and
    # the TUI would then log nowhere for the rest of the run.
    assert :ok = Handler.log(%{level: :warning, msg: {:string, "x"}}, %{config: %{file: file}})

    assert :ok =
             Handler.log(
               %{level: :warning, msg: {:string, "x"}},
               %{config: %{file: "/nonexistent-dir-#{System.unique_integer([:positive])}/x"}}
             )
  end

  # `mix tui` must monitor a pid, not a name. `use ExRatatui.App` generates
  # `start_link/1` as `dispatch_start/1` into `ExRatatui.Server` (default
  # registered name `ExRatatui.Server`), so `CodingAgent.UI.Tui` is a
  # callback module and never a process: the old
  # `Process.whereis(CodingAgent.UI.Tui)` was always nil, the wait fell
  # back to `self()`, and no `:DOWN` ever arrived — `q` stopped the TUI and
  # the VM lingered at an iex-like prompt (review N88).
  test "the mix task waits on the pid start_link returned, not on a name" do
    session = CellSession.new(80, 10)

    start_opts = [
      mod: CodingAgent.UI.Tui,
      test_mode: {80, 10},
      # `name: nil` — the DEFAULT registered name is `ExRatatui.Server`, and
      # this module is `async: true`: another test's server may hold it.
      name: nil,
      transport: {:cell_session, session, fn _diff -> :ok end}
    ]

    {:ok, tui} = Server.start_link(start_opts)

    # the premise of the bug: the name the task used to try is unregistered
    refute Process.whereis(CodingAgent.UI.Tui)
    assert is_pid(tui) and Process.alive?(tui)

    test_pid = self()
    spawn(fn -> Process.sleep(50) && GenServer.stop(tui) end)

    # halting the VM here would kill the test run, so the task's one
    # side effect is injected: the seam proves the DOWN was seen and that
    # the halt sits behind it.
    halt = fn code ->
      send(test_pid, {:halted, code})
      :ok
    end

    assert :ok = Tui.await_tui(tui, halt)
    assert_receive {:halted, 0}
  end
end
