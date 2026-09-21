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

  # Move the picker selection onto the row for `id` (rows are newest-first,
  # so walk down until the visible row matches).
  defp select_row(pid, id) do
    st = sync(pid)
    target = find_index(picker_visible(st), id)
    current = st.picker_index

    cond do
      target == current -> :ok
      target > current -> Enum.each(1..(target - current), fn _ -> key(pid, "down") end)
      true -> Enum.each(1..(current - target), fn _ -> key(pid, "up") end)
    end
  end

  defp find_index(rows, id), do: Enum.find_index(rows, &(&1.id == id))

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

    test "the picker names the active store (ADR 020 R16)", %{root: root} do
      pid = start_picker(root)
      joined = Enum.join(buffer(pid), "\n")

      # the header states which store these sessions belong to
      assert joined =~ "store: "
      assert joined =~ CodingAgent.Core.Session.Store.path()
    end

    test "the picker advertises every management verb, incl. prune and search", %{root: root} do
      pid = start_picker(root)
      joined = Enum.join(buffer(pid), "\n")

      for verb <- [
            "enter=resume",
            "n=new",
            "a=all/dir",
            "/=filter",
            "s=search",
            "d=delete",
            "D=delete all",
            "r=rename",
            "P=prune age",
            "S=prune size"
          ] do
        assert joined =~ verb, "missing hint #{verb}"
      end
    end

    test "`s` searches the display view and shows the matching text", %{root: root, ids: ids} do
      [a, _b] = ids
      :ok = CodingAgent.Core.Session.Store.append_display(a, :assistant, "the widget factory")

      pid = start_picker(root)

      key(pid, "s")
      assert match?({:search, ""}, sync(pid).picker_op)

      Enum.each(String.graphemes("widget"), &key(pid, &1))

      st = sync(pid)
      assert st.picker_search == "widget"
      visible_ids = Enum.map(picker_visible(st), & &1.id)
      assert visible_ids == [a]

      # the matching display row renders beneath the session row
      joined = Enum.join(buffer(pid), "\n")
      assert joined =~ "widget factory"

      # enter commits the query: the prompt closes and the header names the
      # scope "search" (the summary line replaces the prompt)
      key(pid, "enter")
      assert sync(pid).picker_op == nil
      assert Enum.join(buffer(pid), "\n") =~ "[search]"

      # esc in the prompt clears the query and restores the listing
      key(pid, "s")
      key(pid, "escape")
      st2 = sync(pid)
      assert st2.picker_search == nil
      assert length(picker_visible(st2)) == 2
    end

    test "`e` exports the selected session as Markdown into its scope root", %{
      root: root,
      ids: ids
    } do
      [a, _b] = ids
      :ok = CodingAgent.Core.Session.Store.append_display(a, :user, "please export me")

      pid = start_picker(root)
      # select the row for `a` (rows are newest-first; find its index)
      select_row(pid, a)

      key(pid, "e")

      path = Path.join(root, "#{a}.md")
      wait_until(fn -> File.exists?(path) end)
      body = File.read!(path)
      assert body =~ "# Session #{a}"
      assert body =~ "please export me"
      assert body =~ "not a resumable session"
    end

    test "`E` exports JSON with tool arguments", %{root: root, ids: ids} do
      [a, _b] = ids

      :ok =
        CodingAgent.Core.Session.Store.append_display(a, :tool, "output",
          meta: {:tool, "read_file", %{"path" => "lib/x.ex"}}
        )

      pid = start_picker(root)
      select_row(pid, a)

      key(pid, "E")

      path = Path.join(root, "#{a}.json")
      wait_until(fn -> File.exists?(path) end)
      decoded = path |> File.read!() |> Jason.decode!()
      tool = Enum.find(decoded["entries"], &(&1["kind"] == "tool"))
      assert tool["tool"] == "read_file"
      assert tool["arguments"] == %{"path" => "lib/x.ex"}
    end

    test "`s` with no matches shows an empty picker", %{root: root} do
      pid = start_picker(root)

      key(pid, "s")
      Enum.each(String.graphemes("nothingmatchesthis"), &key(pid, &1))

      assert picker_visible(sync(pid)) == []
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

    test "`P` prunes sessions older than N days after confirmation", %{root: root, ids: ids} do
      # backdate one seeded session's saved_at (the store's prune key)
      [old_id | _] = ids

      eleven_days_ago =
        DateTime.add(DateTime.utc_now(), -11 * 86_400) |> DateTime.to_unix(:millisecond)

      :ok = CodingAgent.Core.Session.Store.debug_set_saved_at(old_id, eleven_days_ago)

      pid = start_picker(root)

      key(pid, "P")
      assert match?({:prune, ""}, sync(pid).picker_op)

      # type "10" then enter -> armed confirmation, not yet deleted
      key(pid, "1")
      key(pid, "0")

      key(pid, "enter")
      assert match?({:prune_confirm, [^old_id], _why}, sync(pid).picker_op)
      assert {:ok, _} = CodingAgent.Core.Session.Store.load(old_id)

      key(pid, "y")
      assert {:error, :enoent} = CodingAgent.Core.Session.Store.load(old_id)
      # the fresh session survives; the picker reloaded and closed the prompt
      assert sync(pid).picker_op == nil
      assert Enum.any?(CodingAgent.Core.Session.Store.list_in(root), &(&1.id != old_id))
    end

    test "`S` prunes sessions larger than N MB after confirmation", %{root: root, ids: ids} do
      # one seeded session is padded past 1 MB; the other stays tiny
      [big_id, small_id] = ids

      big_messages =
        for i <- 1..80, do: ReqLLM.Context.user(String.duplicate("x", 16_000) <> "#{i}")

      big_context = ReqLLM.Context.new(big_messages)

      big_state =
        CodingAgent.Core.Session.State.new(
          id: big_id,
          context: big_context,
          model: "m",
          status: :idle,
          scope_root: root,
          policy: CodingAgent.Core.Permissions.load(nil, nil)
        )

      :ok = CodingAgent.Core.Session.Store.save(big_state)

      pid = start_picker(root)

      key(pid, "S")
      assert match?({:prune_size, ""}, sync(pid).picker_op)

      # threshold 1 MB
      key(pid, "1")
      key(pid, "enter")

      assert match?({:prune_confirm, [^big_id], _why}, sync(pid).picker_op)
      # not yet deleted
      assert {:ok, _} = CodingAgent.Core.Session.Store.load(big_id)

      key(pid, "y")
      assert {:error, :enoent} = CodingAgent.Core.Session.Store.load(big_id)
      # the small session survives
      assert {:ok, _} = CodingAgent.Core.Session.Store.load(small_id)
      assert sync(pid).picker_op == nil
    end

    test "`S` with nothing large enough reports and deletes nothing", %{root: root, ids: ids} do
      pid = start_picker(root)

      key(pid, "S")
      key(pid, "9")
      key(pid, "9")
      key(pid, "enter")

      assert sync(pid).picker_op == nil

      for id <- ids do
        assert {:ok, _} = CodingAgent.Core.Session.Store.load(id)
      end
    end

    test "`P` with nothing old enough reports and deletes nothing", %{root: root, ids: ids} do
      pid = start_picker(root)

      key(pid, "P")
      key(pid, "3")
      key(pid, "0")
      key(pid, "enter")

      # no sessions are 30 days old; the prompt closes, both survive
      assert sync(pid).picker_op == nil

      for id <- ids do
        assert {:ok, _} = CodingAgent.Core.Session.Store.load(id)
      end
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
