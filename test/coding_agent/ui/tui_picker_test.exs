defmodule CodingAgent.UI.TuiPickerTest do
  use ExUnit.Case, async: false

  @tmp_root System.tmp_dir!() |> Path.join("agent-picker-#{System.unique_integer()}")

  setup do
    File.mkdir_p!(@tmp_root)

    # sweep leftovers from previous test runs (store dir is shared)
    Enum.each(CodingAgent.Core.Session.Store.list(), fn %{id: id} ->
      if String.starts_with?(id, "pick-"), do: CodingAgent.Core.Session.Store.delete(id)
    end)

    # two persisted sessions scoped to the picker cwd
    Enum.each(["alpha", "beta"], fn name ->
      id = "pick-#{name}-#{System.unique_integer([:positive])}"

      context = ReqLLM.Context.new() |> ReqLLM.Context.append(ReqLLM.Context.user("hi"))

      state =
        CodingAgent.Core.Session.State.new(
          id: id,
          context: context,
          model: "m",
          status: :idle,
          scope_root: @tmp_root,
          policy: CodingAgent.Core.Permissions.load(nil, nil)
        )

      CodingAgent.Core.Session.Store.save(state)
    end)

    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    %{root: @tmp_root}
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
    Process.sleep(700)

    rt = :sys.get_state(pid)
    st = rt.user_state
    # picker active, session NOT started (session_id nil)
    assert is_list(st.picker) and length(st.picker) == 2,
           "picker: #{inspect(st.picker)}"

    assert st.session_id == nil

    # rendered: both ids visible, the selected row marked
    rows = ExRatatui.get_buffer_content(rt.terminal_ref) |> String.split("\n")
    joined = Enum.join(rows, "\n")
    assert joined =~ "sessions"
    assert joined =~ "pick-alpha" or joined =~ "pick-beta"

    # down to the second row, enter -> resumed session attached
    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{kind: "press", code: "down"})
    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{kind: "press", code: "enter"})
    Process.sleep(700)

    st2 = :sys.get_state(pid).user_state
    assert st2.session_id != nil
    assert st2.picker == nil
    assert st2.status == :idle
  end

  test "n starts a fresh session from the picker", %{root: root} do
    pid = start_picker(root)
    Process.sleep(700)

    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{kind: "press", code: "n"})
    Process.sleep(700)

    st = :sys.get_state(pid).user_state
    assert st.session_id != nil
    assert st.picker == nil
    # a NEW session: id does not collide with the seeded ones
    assert st.session_id =~ "tui-"
  end

  test "q quits from the picker without creating a session", %{root: root} do
    pid = start_picker(root)
    Process.sleep(700)

    ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{kind: "press", code: "q"})
    Process.sleep(300)

    # the TUI process stopped
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

    Process.sleep(700)
    st = :sys.get_state(pid).user_state
    # picker skipped: a session attached immediately
    assert st.picker == nil
    assert st.session_id != nil
  end

  test "picker renders rows with id, status and age" do
    pid = start_picker(@tmp_root)
    Process.sleep(700)
    rt = :sys.get_state(pid)
    rows = ExRatatui.get_buffer_content(rt.terminal_ref) |> String.split("\n")
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
