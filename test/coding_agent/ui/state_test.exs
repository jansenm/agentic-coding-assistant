# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.StateTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Core.Session.{Timing, Usage}
  alias CodingAgent.UI.{State, Tabs}

  test "base/1 carries the neutral state the old mount literals spelled out" do
    opts = [test_pid: self(), sidebar: false]
    st = State.base(opts)

    assert st.session_id == nil
    assert st.model == nil
    assert st.status == :idle
    assert %Usage{} = st.session_usage
    assert %Timing{} = st.timing
    assert st.trailer_bytes == 0
    assert st.transcript == []
    assert st.stream == []
    assert st.pending == []
    assert st.tabs == Tabs.new()
    assert st.picker == nil
    assert st.picker_filter == ""
    assert st.picker_all? == false
    assert st.keymap == nil
    assert st.history == []
    assert st.history_index == nil
    # base/1 builds the textarea handle fresh (a resource reference),
    # not a value a compile-time default could share
    assert is_reference(st.textarea)
    assert st.mount_opts == opts
  end

  test "base/1 reads the mount decisions from opts" do
    st = State.base(test_pid: self(), sidebar: false)
    assert st.test_pid == self()
    assert st.sidebar_visible? == false
    assert st.test_mode? == false

    st = State.base(sidebar: true, test_mode: {80, 24})
    assert st.sidebar_visible? == true
    assert st.test_mode? == true

    nil_state = State.base(test_mode: nil)
    assert nil_state.test_mode? == false
  end

  test "picker/4 opens the chooser on the deferred session start" do
    opts = [resume_id: nil]
    sessions = [%{id: "s-1"}, %{id: "s-2"}]

    st = State.picker(opts, sessions, "hi", "/tmp/opencode")
    assert st.picker == sessions
    assert st.picker_opts == opts
    assert st.picker_prompt == "hi"
    assert st.picker_scope == Path.expand("/tmp/opencode")
    assert st.picker_index == 0
    assert st.picker_op == nil
    # no session is attached yet
    assert st.session_id == nil
    assert st.keymap == nil
  end

  test "session/2 fills the mount-resolved fields and keeps every other default" do
    opts = [test_pid: self(), sidebar: false]

    st =
      State.session(opts,
        session_id: "s-1",
        model: "m",
        status: :running,
        stream: [{:assistant, "x"}]
      )

    assert st.session_id == "s-1"
    assert st.model == "m"
    assert st.status == :running
    assert st.stream == [{:assistant, "x"}]
    # untouched fields keep the struct's defaults
    assert st.provider_down? == false
    assert st.menu_popup == nil
    assert st.compaction_window == 0
  end

  test "session/2 crashes on a field that is not in the struct" do
    assert_raise KeyError, fn ->
      State.session([test_pid: self()], not_a_field: 1)
    end
  end

  test "test_session?/1 reads the option's PRESENCE, not its shape" do
    refute State.test_session?([])
    assert State.test_session?(test_mode: {80, 24})
    assert State.test_session?(test_mode: true)
  end
end
