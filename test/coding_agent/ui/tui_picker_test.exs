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

  describe "session manager (ADR 020, slice 1)" do
    test "rows show the storage footprint and the header shows the total", %{root: root} do
      pid = start_picker(root)
      joined = Enum.join(buffer(pid), "\n")

      # each row carries a human size unit (these tiny sessions are B/KB)
      assert joined =~ " B" or joined =~ " KB"
      # the summary line states the count and the total footprint
      assert joined =~ "2 session(s)"
      assert joined =~ "[this dir]"
    end

    test "list entries carry size and scope_root", %{root: root} do
      [entry | _] = CodingAgent.Core.Session.Store.list_in(root)
      assert is_integer(entry.size) and entry.size > 0
      assert Path.expand(entry.scope_root) == Path.expand(root)
    end

    test "`a` widens the source to the whole store and names the scope column", %{root: root} do
      pid = start_picker(root)
      assert sync(pid).picker_all? == false

      key(pid, "a")
      st = sync(pid)
      assert st.picker_all? == true
      # the box retitles and the header names the whole store
      joined = Enum.join(buffer(pid), "\n")
      assert joined =~ "all sessions"
      assert joined =~ "[all]"
    end

    test "`/` filters the visible rows live", %{root: root} do
      pid = start_picker(root)

      key(pid, "/")
      # type a prefix that matches only one seeded id
      Enum.each(String.graphemes("alpha"), &key(pid, &1))

      st = sync(pid)
      assert st.picker_filter == "alpha"
      visible_ids = Enum.map(picker_visible(st), & &1.id)
      assert length(visible_ids) == 1
      assert hd(visible_ids) =~ "alpha"

      # enter commits (keeps the filter)
      key(pid, "enter")
      st2 = sync(pid)
      assert st2.picker_op == nil
      assert st2.picker_filter == "alpha"

      # esc (in filter mode) clears it
      key(pid, "/")
      key(pid, "escape")
      assert sync(pid).picker_filter == ""
    end

    test "`D` deletes every VISIBLE session after confirmation", %{root: root} do
      pid = start_picker(root)
      assert length(sync(pid).picker) == 2

      key(pid, "D")
      assert match?({:delete_many, _}, sync(pid).picker_op)

      key(pid, "y")

      assert CodingAgent.Core.Session.Store.list_in(root) == []
      # the delete is a management action; the picker stays open even
      # though the directory is now empty
      assert sync(pid).picker_op == nil
    end

    test "`D` with a filter deletes only the filtered rows", %{root: root} do
      pid = start_picker(root)

      # filter to one of the two, then bulk-delete only that one
      key(pid, "/")
      Enum.each(String.graphemes("beta"), &key(pid, &1))
      key(pid, "enter")
      key(pid, "D")
      key(pid, "y")

      remaining = CodingAgent.Core.Session.Store.list_in(root)
      assert length(remaining) == 1
      assert hd(remaining).id =~ "alpha"
    end

    test "single `d` still deletes one (regression)", %{root: root} do
      pid = start_picker(root)
      selected = picker_visible(sync(pid)) |> Enum.at(sync(pid).picker_index)

      key(pid, "d")
      key(pid, "y")

      remaining_ids = Enum.map(CodingAgent.Core.Session.Store.list_in(root), & &1.id)
      refute selected.id in remaining_ids
      assert length(remaining_ids) == 1
    end
  end

  # Mirror of Tui.picker_visible/1 for assertions: reads the raw source
  # and filter off the state (the function is private).
  defp picker_visible(state) do
    filter = String.trim(Map.get(state, :picker_filter, ""))

    if filter == "" do
      state.picker
    else
      needle = String.downcase(filter)

      Enum.filter(state.picker, fn s ->
        String.downcase("#{s.id} #{s.model || ""} #{s.status} #{s.scope_root || ""}")
        |> String.contains?(needle)
      end)
    end
  end
end
