defmodule CodingAgent.UI.TuiHistoryTest do
  use CodingAgent.TuiCase, async: true

  test "ctrl-p recalls the last sent prompt; ctrl-n returns to the live draft" do
    {:ok, pid} =
      CodingAgent.UI.Tui.start_link(
        name: nil,
        test_mode: {80, 24},
        scope_root: System.tmp_dir!(),
        scope: System.tmp_dir!()
      )

    key(pid, "h")
    key(pid, "enter", ["ctrl"])

    # no crash on ctrl-p (was: history_step stub returned nil as state)
    key(pid, "p", ["ctrl"])

    st = sync(pid)
    assert st.history_index == 0
    assert Process.alive?(pid)

    # back to the live draft
    key(pid, "n", ["ctrl"])

    st2 = sync(pid)
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
        id: "recall-seed-#{System.unique_integer([:positive])}",
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
        resume_id: st.id
      )

    # recall is seeded synchronously in mount
    st0 = sync(pid)
    assert st0.history == ["first prompt", "second prompt"]

    key(pid, "p", ["ctrl"])

    assert sync(pid).history_index == 0
  end

  test "picker delete: d arms, y deletes and refreshes the list" do
    root = System.tmp_dir!() |> Path.join("pickdel-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    a = "del-a-#{System.unique_integer([:positive])}"
    b = "del-b-#{System.unique_integer([:positive])}"
    save_session(a, root)
    save_session(b, root)

    {:ok, pid} =
      CodingAgent.UI.Tui.start_link(
        name: nil,
        test_mode: {80, 24},
        scope_root: root,
        scope: root,
        picker: true
      )

    key(pid, "d")

    # not yet deleted until y; whatever row is selected is only ARMED
    st = sync(pid)
    assert {:delete, armed} = st.picker_op
    assert armed in [a, b]
    assert File.exists?(CodingAgent.Core.Session.Store.path(armed))

    key(pid, "y")

    st2 = sync(pid)
    assert st2.picker_op == nil
    assert Enum.map(st2.picker, & &1.id) == [a, b] -- [armed]
    refute File.exists?(CodingAgent.Core.Session.Store.path(armed))

    # esc cancels a delete prompt without deleting
    key(pid, "d")
    key(pid, "esc")

    st3 = sync(pid)
    assert st3.picker_op == nil
  end

  test "picker rename: r + typing + enter renames in place" do
    root = System.tmp_dir!() |> Path.join("pickren-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    ctx = ReqLLM.Context.new([ReqLLM.Context.user("p")])

    st =
      CodingAgent.Core.Session.State.new(
        id: "ren-a-#{System.unique_integer([:positive])}",
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

    for c <- ["r", "2", "b", "enter"], do: key(pid, c)

    st2 = sync(pid)
    assert st2.picker_op == nil
    assert Enum.map(st2.picker, & &1.id) == ["2b"]
    assert File.exists?(CodingAgent.Core.Session.Store.path("2b"))
    refute File.exists?(CodingAgent.Core.Session.Store.path(st.id))
  end

  defp save_session(id, root) do
    ctx = ReqLLM.Context.new([ReqLLM.Context.user("p")])

    CodingAgent.Core.Session.Store.save(
      CodingAgent.Core.Session.State.new(
        id: id,
        context: ctx,
        model: "m",
        status: :idle,
        scope_root: root
      )
    )
  end
end
