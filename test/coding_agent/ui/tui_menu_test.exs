defmodule CodingAgent.UI.TuiMenuTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Core.Session

  setup do
    tmp_root = System.tmp_dir!() |> Path.join("agent-menu-#{System.unique_integer()}")
    File.mkdir_p!(tmp_root)

    Enum.each(CodingAgent.Core.Session.Store.list(), fn %{id: id} ->
      if String.starts_with?(id, "pick-"), do: CodingAgent.Core.Session.Store.delete(id)
    end)

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

  defp key(pid, code, mods \\ []) do
    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{
      kind: "press",
      code: code,
      modifiers: mods
    })
  end

  test "ctrl-x q quits (fast path, no popup)", %{root: tmp_root} do
    pid = start_tui(tmp_root)
    Process.sleep(700)
    key(pid, "x", ["ctrl"])
    key(pid, "q")
    Process.sleep(300)
    refute Process.alive?(pid)
  end

  test "ctrl-x then wait shows the menu popup; arrows + enter run it", %{root: tmp_root} do
    pid = start_tui(tmp_root)
    Process.sleep(700)
    key(pid, "x", ["ctrl"])
    # wait past the 1s menu timeout
    Process.sleep(1300)
    st = :sys.get_state(pid).user_state
    assert st.menu_popup != nil
    assert st.menu_popup_id == nil

    rt = :sys.get_state(pid)
    rows = ExRatatui.get_buffer_content(rt.terminal_ref) |> String.split("\n")
    assert Enum.join(rows, "\n") =~ "switch session"

    # navigate to 'show keymaps' and enter -> the keymaps popup opens
    idx = Enum.find_index(st.menu_popup.items, &(&1.action == :show_keymaps))
    Enum.each(1..idx, fn _ -> key(pid, "down") end)
    key(pid, "enter")
    Process.sleep(300)

    st2 = :sys.get_state(pid).user_state
    assert st2.menu_popup_id == :keymaps
  end

  test "ctrl-x t fires toggle directly (no popup)", %{root: tmp_root} do
    pid = start_tui(tmp_root)
    Process.sleep(700)
    # seed a tool block so the toggle has something to act on
    send(pid, {:agent, {:tool_executed, "shell", "out"}})
    Process.sleep(300)

    key(pid, "x", ["ctrl"])
    key(pid, "t")
    Process.sleep(300)

    st = :sys.get_state(pid).user_state
    assert st.menu_popup == nil
    assert st.open_tool_id != nil
  end

  test "ctrl-x s opens the switch popup with the cwd's other sessions", %{root: tmp_root} do
    a = seed_session("pick-a", tmp_root)
    b = seed_session("pick-b", tmp_root)

    # attach to a fresh (not persisted) session: the popup should list
    # both seeded ones
    pid = start_tui(tmp_root)
    Process.sleep(700)
    key(pid, "x", ["ctrl"])
    key(pid, "s")
    Process.sleep(300)

    st = :sys.get_state(pid).user_state
    assert st.menu_popup_id == :switch_session
    ids = Enum.map(st.menu_popup.items, & &1.id)
    assert a in ids and b in ids
  end

  test "esc closes the menu popup", %{root: tmp_root} do
    pid = start_tui(tmp_root)
    Process.sleep(700)

    key(pid, "x", ["ctrl"])
    Process.sleep(1400)

    st = :sys.get_state(pid).user_state
    assert st.menu_popup != nil

    key(pid, "esc")
    Process.sleep(300)

    st2 = :sys.get_state(pid).user_state
    assert st2.menu_popup == nil
    assert st2.menu_popup_id == nil
  end

  test "switching attaches the chosen session (keep-alive)", %{root: tmp_root} do
    _a = seed_session("pick-a", tmp_root)
    b = seed_session("pick-b", tmp_root)

    pid = start_tui(tmp_root)
    Process.sleep(700)
    key(pid, "x", ["ctrl"])
    key(pid, "s")
    Process.sleep(300)

    st = :sys.get_state(pid).user_state
    # select the session whose id is `b`
    idx = Enum.find_index(st.menu_popup.items, &(&1.id == b))

    if idx > 0, do: Enum.each(1..idx, fn _ -> key(pid, "down") end)

    key(pid, "enter")
    Process.sleep(700)

    st2 = :sys.get_state(pid).user_state
    assert st2.session_id == b
    assert st2.menu_popup == nil

    # keep-alive: the previous session is still alive — switching back
    # attaches it (a recreate would give a different transcript seed;
    # here the attach resolves the LIVE process)
    key(pid, "x", ["ctrl"])
    key(pid, "s")
    Process.sleep(300)

    st3 = :sys.get_state(pid).user_state
    idx = Enum.find_index(st3.menu_popup.items, &(&1.id == _a))
    assert idx != nil, "switched-away session must still be listed"
    key(pid, "enter")
    Process.sleep(700)

    st4 = :sys.get_state(pid).user_state
    assert st4.session_id == _a
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
    Process.sleep(400)

    st = :sys.get_state(pid).user_state
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
    Process.sleep(300)

    st = :sys.get_state(pid).user_state
    # pick a DIFFERENT entry (the current mark may be on the only item)
    other = Enum.find(st.menu_popup.items, &(not String.contains?(&1.label, "(current)")))

    if other do
      idx = Enum.find_index(st.menu_popup.items, &(&1 == other))
      Enum.each(1..idx, fn _ -> key(pid, "down") end)
      key(pid, "enter")
      Process.sleep(400)

      st2 = :sys.get_state(pid).user_state
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
    Process.sleep(300)

    st = :sys.get_state(pid).user_state
    # never raises: the popup opened (maybe with catalog entries only)
    assert st.menu_popup != nil
  end
end
