defmodule CodingAgent.UI.AltDecodeTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.AltDecode

  test "ESC then key within the window decodes to alt-key" do
    {events, st} =
      AltDecode.push(%AltDecode{}, %{key: :esc, time_ms: 100})

    assert events == []
    {events, st} = AltDecode.push(st, %{key: :enter, time_ms: 110})

    assert events == [%{key: :enter, mod: :alt, time_ms: 110}]
    assert st == %AltDecode{}
  end

  test "ESC alone past the window releases a lone ESC" do
    {_, st} = AltDecode.push(%AltDecode{}, %{key: :esc, time_ms: 100})
    {events, st} = AltDecode.drain(st, 200)

    assert events == [%{key: :esc, mod: :none, time_ms: 100}]
    assert st == %AltDecode{}
  end

  test "ESC then key after the window: lone ESC + plain key" do
    {_, st} = AltDecode.push(%AltDecode{}, %{key: :esc, time_ms: 100})
    {events, _} = AltDecode.push(st, %{key: :enter, time_ms: 500})

    assert events == [
             %{key: :esc, mod: :none, time_ms: 100},
             %{key: :enter, mod: :none, time_ms: 500}
           ]
  end

  test "plain keys pass through untouched" do
    {events, st} = AltDecode.push(%AltDecode{}, %{key: :a, time_ms: 10})

    assert events == [%{key: :a, mod: :none, time_ms: 10}]
    assert st == %AltDecode{}
  end

  test "window boundary: exactly at the window still counts as chord" do
    {_, st} = AltDecode.push(%AltDecode{}, %{key: :esc, time_ms: 100})
    {events, _} = AltDecode.push(st, %{key: :enter, time_ms: 100 + AltDecode.esc_window_ms()})

    assert [%{mod: :alt}] = events
  end
end
