defmodule CodingAgent.UI.TuiHistoryTest do
  use ExUnit.Case, async: false

  setup do
    Process.sleep(50)
    :ok
  end

  defp key(pid, code, mods \\ []) do
    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{
      kind: "press",
      code: code,
      modifiers: mods
    })
  end

  test "ctrl-p recalls the last sent prompt; ctrl-n returns to the live draft" do
    {:ok, pid} =
      CodingAgent.UI.Tui.start_link(
        name: nil,
        test_mode: {80, 24},
        scope_root: System.tmp_dir!(),
        scope: System.tmp_dir!()
      )

    Process.sleep(600)

    key(pid, "h")
    Process.sleep(150)
    key(pid, "enter", ["ctrl"])
    Process.sleep(400)

    # no crash on ctrl-p (was: history_step stub returned nil as state)
    key(pid, "p", ["ctrl"])
    Process.sleep(300)

    st = :sys.get_state(pid).user_state
    assert st.history_index == 0
    assert Process.alive?(pid)

    # back to the live draft
    key(pid, "n", ["ctrl"])
    Process.sleep(300)

    st2 = :sys.get_state(pid).user_state
    assert st2.history_index == nil
    assert Process.alive?(pid)
  end

  test "attaching a session seeds ctrl-p recall from its past user prompts" do
    root = System.tmp_dir!() |> Path.join("recall-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    ctx =
      ReqLLM.Context.new([
        ReqLLM.Context.user("first prompt"),
        ReqLLM.Context.assistant("answer"),
        ReqLLM.Context.user("second prompt")
      ])

    st =
      CodingAgent.Core.Session.State.new(
        id: "recall-seed",
        context: ctx,
        model: "m",
        status: :idle,
        scope_root: root
      )

    CodingAgent.Core.Session.Store.save(st)

    {:ok, pid} =
      CodingAgent.UI.Tui.start_link(
        name: nil,
        test_mode: {80, 24},
        scope_root: root,
        scope: root,
        resume_id: "recall-seed"
      )

    Process.sleep(700)

    st0 = :sys.get_state(pid).user_state
    assert st0.history == ["first prompt", "second prompt"]

    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{
      kind: "press",
      code: "p",
      modifiers: ["ctrl"]
    })

    Process.sleep(300)

    st1 = :sys.get_state(pid).user_state
    assert st1.history_index == 0
  end

  test "picker delete: d arms, y deletes and refreshes the list" do
    root = System.tmp_dir!() |> Path.join("pickdel-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for i <- 1..2 do
      ctx = ReqLLM.Context.new([ReqLLM.Context.user("p#{i}")])

      st =
        CodingAgent.Core.Session.State.new(
          id: "del-#{i}",
          context: ctx,
          model: "m",
          status: :idle,
          scope_root: root
        )

      CodingAgent.Core.Session.Store.save(st)
    end

    {:ok, pid} =
      CodingAgent.UI.Tui.start_link(
        name: nil,
        test_mode: {80, 24},
        scope_root: root,
        scope: root,
        picker: true
      )

    Process.sleep(700)

    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{kind: "press", code: "d"})
    Process.sleep(150)

    # not yet deleted until y
    st = :sys.get_state(pid).user_state
    assert match?({:delete, "del-2"}, st.picker_op)
    assert File.exists?(CodingAgent.Core.Session.Store.path("del-1"))

    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{kind: "press", code: "y"})
    Process.sleep(400)

    st2 = :sys.get_state(pid).user_state
    assert st2.picker_op == nil
    assert Enum.map(st2.picker, & &1.id) == ["del-1"]
    assert File.exists?(CodingAgent.Core.Session.Store.path("del-1"))

    # esc cancels a delete prompt without deleting
    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{kind: "press", code: "d"})
    Process.sleep(150)
    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{kind: "press", code: "esc"})
    Process.sleep(300)

    st3 = :sys.get_state(pid).user_state
    assert st3.picker_op == nil
    assert File.exists?(CodingAgent.Core.Session.Store.path("del-1"))
  end

  test "picker rename: r + typing + enter renames in place" do
    root = System.tmp_dir!() |> Path.join("pickren-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    ctx = ReqLLM.Context.new([ReqLLM.Context.user("p")])

    st =
      CodingAgent.Core.Session.State.new(
        id: "ren-a",
        context: ctx,
        model: "m",
        status: :idle,
        scope_root: root
      )

    CodingAgent.Core.Session.Store.save(st)

    {:ok, pid} =
      CodingAgent.UI.Tui.start_link(
        name: nil,
        test_mode: {80, 24},
        scope_root: root,
        scope: root,
        picker: true
      )

    Process.sleep(700)

    for c <- ["r", "2", "b", "enter"] do
      ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{kind: "press", code: c})
      Process.sleep(100)
    end

    Process.sleep(300)
    st2 = :sys.get_state(pid).user_state
    assert st2.picker_op == nil
    assert Enum.map(st2.picker, & &1.id) == ["2b"]
    assert File.exists?(CodingAgent.Core.Session.Store.path("2b"))
    refute File.exists?(CodingAgent.Core.Session.Store.path("ren-a"))
  end
end
