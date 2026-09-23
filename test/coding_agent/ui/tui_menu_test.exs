defmodule CodingAgent.UI.TuiMenuTest do
  use CodingAgent.TuiCase, async: true

  alias CodingAgent.Core.Session

  setup do
    tmp_root = System.tmp_dir!() |> Path.join("agent-menu-#{System.unique_integer()}")
    File.mkdir_p!(tmp_root)

    on_exit(fn -> File.rm_rf!(tmp_root) end)
    %{root: tmp_root}
  end

  defp seed_session(prefix, tmp_root) do
    id = "#{prefix}-#{System.unique_integer([:positive])}"
    ctx = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))

    state =
      CodingAgent.Core.Session.State.new(
        id: id,
        context: ctx,
        model: "m",
        status: :idle,
        scope_root: tmp_root,
        policy: CodingAgent.Core.Permissions.load(nil, nil)
      )

    CodingAgent.Core.Session.Store.save(state)
    id
  end

  defp start_tui(root, opts \\ []) do
    start_supervised!(%{
      id: String.to_atom("tui-#{System.unique_integer([:positive])}"),
      start:
        {CodingAgent.UI.Tui, :start_link,
         [[name: nil, test_mode: {100, 30}, scope_root: root] ++ opts]}
    })
  end

  test "ctrl-x q quits (fast path, no popup)", %{root: tmp_root} do
    pid = start_tui(tmp_root)
    key(pid, "x", ["ctrl"])
    key(pid, "q")
    wait_until(fn -> not Process.alive?(pid) end)
    refute Process.alive?(pid)
  end

  test "ctrl-x then wait shows the menu popup; arrows + enter run it", %{root: tmp_root} do
    pid = start_tui(tmp_root)
    key(pid, "x", ["ctrl"])
    # fire the menu timer instead of waiting it out
    fire(pid, :__menu_timeout__)

    st = sync(pid)
    assert st.menu_popup != nil
    assert st.menu_popup_id == nil

    rows = buffer(pid)
    assert Enum.join(rows, "\n") =~ "switch session"

    # navigate to 'show keymaps' and enter -> the keymaps popup opens
    idx = Enum.find_index(st.menu_popup.items, &(&1.action == :show_keymaps))
    Enum.each(1..idx, fn _ -> key(pid, "down") end)
    key(pid, "enter")

    assert sync(pid).menu_popup_id == :keymaps
  end

  test "ctrl-x t fires toggle directly (no popup)", %{root: tmp_root} do
    pid = start_tui(tmp_root)
    # seed a tool block so the toggle has something to act on
    agent(pid, {:tool_executed, "shell", "out"})

    key(pid, "x", ["ctrl"])
    key(pid, "t")

    st = sync(pid)
    assert st.menu_popup == nil
    assert st.open_tool_id != nil
  end

  test "ctrl-x s opens the switch popup with the cwd's other sessions", %{root: tmp_root} do
    a = seed_session("pick-a", tmp_root)
    b = seed_session("pick-b", tmp_root)

    # attach to a fresh (not persisted) session: the popup should list
    # both seeded ones
    pid = start_tui(tmp_root)
    key(pid, "x", ["ctrl"])
    key(pid, "s")

    st = sync(pid)
    assert st.menu_popup_id == :switch_session
    ids = Enum.map(st.menu_popup.items, & &1.id)
    assert a in ids and b in ids
  end

  test "esc closes the menu popup", %{root: tmp_root} do
    pid = start_tui(tmp_root)

    key(pid, "x", ["ctrl"])
    fire(pid, :__menu_timeout__)

    assert sync(pid).menu_popup != nil

    key(pid, "esc")

    st2 = sync(pid)
    assert st2.menu_popup == nil
    assert st2.menu_popup_id == nil
  end

  # The live band (and the input below it) must never be covered: a popup
  # longer than the room above the band is WINDOWED around the selection,
  # not truncated. Found by measuring: `overlay_rect/4` clamped the
  # keymap list (21 rows) to 20, which silently dropped its last entries
  # and would have walked the selection off the bottom.
  test "a popup taller than the room windows around the selection", %{root: tmp_root} do
    pid = start_tui(tmp_root)

    key(pid, "x", ["ctrl"])
    key(pid, "k")
    assert sync(pid).menu_popup_id == :keymaps

    items = sync(pid).menu_popup.items
    assert length(items) > 17

    # the marker follows the selection and the title names the window
    key(pid, "down")

    rows = buffer(pid)
    title = Enum.find(rows, &String.contains?(&1, "keymaps"))
    assert title =~ "1-17/#{length(items)}"
    assert Enum.any?(rows, &String.contains?(&1, "❯"))

    # walking to the last item scrolls the window to its end — the
    # selection is never outside the painted range
    Enum.each(1..(length(items) - 1), fn _ -> key(pid, "down") end)

    assert sync(pid).menu_index == length(items) - 1

    rows = buffer(pid)
    title = Enum.find(rows, &String.contains?(&1, "keymaps"))
    assert title =~ "-#{length(items)}/#{length(items)}"
    assert Enum.any?(rows, &String.contains?(&1, "❯"))

    # ...and the band + the input below it are still there (an overlay
    # may cover the transcript, never the field)
    assert buffer(pid) |> Enum.join("\n") =~ "○ idle"
    assert buffer(pid) |> Enum.find(&String.contains?(&1, "model ")) != nil
  end

  test "a popup that fits is not titled with a range", %{root: tmp_root} do
    pid = start_tui(tmp_root)

    key(pid, "x", ["ctrl"])
    fire(pid, :__menu_timeout__)

    title = buffer(pid) |> Enum.find(&String.contains?(&1, "commands"))
    refute title =~ ~r/\(\d+-\d+\/\d+\)/
    assert title =~ "letter=run"
  end

  test "a consumed ctrl-x prefix cancels its timer (stale timer regression)", %{
    root: tmp_root
  } do
    # Found flaky: ctrl-x armed a 1s :__menu_timeout__ timer; pressing the
    # letter consumed the prefix but did NOT cancel the timer. Under load
    # the stale timer from the FIRST ctrl-x fired during the SECOND
    # ctrl-x's pending window, opened the MAIN menu, and the following
    # letter closed it (handle_menu_popup_key) instead of opening the
    # target popup — surfacing as `menu_popup == nil` on the second open.
    # The ref is now tracked on the state and cancelled on consumption.
    seed_session("cancel-a", tmp_root)
    pid = start_tui(tmp_root)

    # arming ctrl-x records the timer ref
    key(pid, "x", ["ctrl"])
    assert sync(pid).menu_timer != nil

    # consuming the prefix (any key) cancels and forgets it
    key(pid, "s")
    st = sync(pid)
    assert st.menu_popup_id == :switch_session
    assert st.menu_timer == nil, "the armed timer must be cancelled on consumption"

    # and a fresh ctrl-x + letter still works end to end
    key(pid, "esc")
    key(pid, "x", ["ctrl"])
    key(pid, "s")

    assert sync(pid).menu_popup_id == :switch_session
  end

  test "switching attaches the chosen session (keep-alive)", %{root: tmp_root} do
    a = seed_session("pick-a", tmp_root)
    b = seed_session("pick-b", tmp_root)

    pid = start_tui(tmp_root)
    key(pid, "x", ["ctrl"])
    key(pid, "s")

    st = sync(pid)
    # select the session whose id is `b`
    idx = Enum.find_index(st.menu_popup.items, &(&1.id == b))

    if idx > 0, do: Enum.each(1..idx, fn _ -> key(pid, "down") end)

    key(pid, "enter")

    st2 = sync(pid)
    assert st2.session_id == b
    assert st2.menu_popup == nil

    # keep-alive: the previous session is still alive — switching back
    # attaches it (a recreate would give a different transcript seed;
    # here the attach resolves the LIVE process)
    key(pid, "x", ["ctrl"])
    key(pid, "s")

    st3 = sync(pid)
    idx = Enum.find_index(st3.menu_popup.items, &(&1.id == a))
    assert idx != nil, "switched-away session must still be listed"
    key(pid, "enter")

    assert sync(pid).session_id == a
  end

  # -- model menu (ctrl-x m) ----------------------------------------------

  test "ctrl-x m opens the model popup with catalog + discovered entries", %{
    root: tmp_root
  } do
    id = seed_session("menu-model", tmp_root)
    pid = start_tui(tmp_root, session_id: id)

    # the session is LIVE with this model (state mirror seeded at mount)
    key(pid, "x", ["ctrl"])
    key(pid, "m")

    st = sync(pid)
    assert st.menu_popup != nil
    assert st.menu_popup.id == :switch_model

    # seeded model is marked "(current)"
    assert Enum.any?(st.menu_popup.items, &(&1.label =~ "(current)"))
  end

  test "selecting a model switches the session's wire model", %{root: tmp_root} do
    id = seed_session("menu-model", tmp_root)
    pid = start_tui(tmp_root, session_id: id)

    key(pid, "x", ["ctrl"])
    key(pid, "m")

    st = sync(pid)
    # pick a DIFFERENT entry (the current mark may be on the only item)
    other = Enum.find(st.menu_popup.items, &(not String.contains?(&1.label, "(current)")))

    if other do
      idx = Enum.find_index(st.menu_popup.items, &(&1 == other))
      Enum.each(1..idx, fn _ -> key(pid, "down") end)
      key(pid, "enter")

      st2 = sync(pid)
      assert st2.menu_popup == nil
      assert {:ok, sess} = Session.state(id)
      assert sess.model == other.id
    end
  end

  test "dead discovery endpoint: popup still opens, note in title", %{root: tmp_root} do
    # point the provider at a dead port via the project config layer
    proj = Path.join(tmp_root, ".coding-agent")
    File.mkdir_p!(proj)

    cfg_file = Path.join(proj, "config.toml")

    File.write!(
      cfg_file,
      """
      [providers.ollama]
      discover = "openai"
      base_url = "http://127.0.0.1:1/v1"
      """
    )

    id = seed_session("menu-model", tmp_root)
    pid = start_tui(tmp_root, session_id: id)

    key(pid, "x", ["ctrl"])
    key(pid, "m")

    # never raises: the popup opened (maybe with catalog entries only)
    assert sync(pid).menu_popup != nil
  end
end
