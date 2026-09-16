defmodule CodingAgent.UI.TuiPickerTest do
  use CodingAgent.TuiCase, async: true

  setup do
    # per-test scope root: list_in/1 filters on it, so tests are isolated
    # by their own root (no shared pick-* sweep needed)
    root = System.tmp_dir!() |> Path.join("agent-picker-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    # two persisted sessions scoped to the picker cwd
    ids =
      for name <- ["alpha", "beta"] do
        id = "pick-#{name}-#{System.unique_integer([:positive])}"

        context = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))

        state =
          CodingAgent.Core.Session.State.new(
            id: id,
            context: context,
            model: "m",
            status: :idle,
            scope_root: root,
            policy: CodingAgent.Core.Permissions.load(nil, nil)
          )

        CodingAgent.Core.Session.Store.save(state)
        id
      end

    %{root: root, ids: ids}
  end

  defp start_picker(root) do
    start_supervised!(%{
      id: String.to_atom("tui-#{System.unique_integer([:positive])}"),
      start:
        {CodingAgent.UI.Tui, :start_link,
         [[name: nil, test_mode: {100, 30}, picker: true, scope_root: root, scope: root]]}
    })
  end

  test "picker shows the cwd's sessions, enter resumes the selected one", %{root: root} do
    pid = start_picker(root)

    rt = runtime(pid)
    st = rt.user_state
    # picker active, session NOT started (session_id nil)
    assert is_list(st.picker) and length(st.picker) == 2,
           "picker: #{inspect(st.picker)}"

    assert st.session_id == nil

    # rendered: both ids visible, the selected row marked
    rows = buffer(pid)
    joined = Enum.join(rows, "\n")
    assert joined =~ "sessions"
    assert joined =~ "pick-alpha" or joined =~ "pick-beta"

    # down to the second row, enter -> resumed session attached
    key(pid, "down")
    key(pid, "enter")

    st2 = sync(pid)
    assert st2.session_id != nil
    assert st2.picker == nil
    assert st2.status == :idle
  end

  test "n starts a fresh session from the picker", %{root: root} do
    pid = start_picker(root)

    key(pid, "n")

    st = sync(pid)
    assert st.session_id != nil
    assert st.picker == nil
    # a NEW session: id does not collide with the seeded ones
    assert st.session_id =~ "tui-"
  end

  test "q quits from the picker without creating a session", %{root: root} do
    pid = start_picker(root)

    key(pid, "q")

    # the TUI process stopped
    wait_until(fn -> not Process.alive?(pid) end)
    refute Process.alive?(pid)
  end

  test "no sessions in cwd -> no picker, fresh session", %{root: root} do
    empty = Path.join(root, "empty-subdir")
    File.mkdir_p!(empty)

    pid =
      start_supervised!(%{
        id: String.to_atom("tui-#{System.unique_integer([:positive])}"),
        start:
          {CodingAgent.UI.Tui, :start_link,
           [[name: nil, test_mode: {100, 30}, picker: true, scope_root: empty]]}
      })

    st = sync(pid)
    # picker skipped: a session attached immediately
    assert st.picker == nil
    assert st.session_id != nil
  end

  test "picker renders rows with id, status and age", %{root: root} do
    pid = start_picker(root)
    rows = buffer(pid)
    joined = Enum.join(rows, "\n")

    # picker box with header + both sessions + age hints
    assert joined =~ "sessions"
    assert joined =~ "❯"
    assert joined =~ "m ago" or joined =~ "now"
    # the selected marker is present and the first visible session
    # row carries it (index 0 is selected by default)
    assert Enum.count(rows, &String.contains?(&1, "❯")) == 1
  end
end
