defmodule CodingAgent.UI.AltDecode do
  @moduledoc """
  ESC-prefix decoding (ADR 011): classic termbox has no modifier
  reporting, so alt-chords arrive as ESC followed by the key event.
  This module pairs them.

  A lone ESC is ambiguous with a chord whose second key never arrives
  (e.g. pressing ESC to close something). We resolve it with a short
  timeout: ESC alone starts a pending state; if a key event follows
  within `@esc_window_ms`, it is delivered as alt-key; if the window
  expires with nothing following, the ESC is delivered alone.

  Usage: the UI event loop feeds key events through `push/2` and
  consumes what `drain/1` returns after each event and on a timer tick
  (the termbox poll loop wakes us anyway).
  """

  @esc_window_ms 25

  def esc_window_ms, do: @esc_window_ms

  @typedoc "Opaque decoder state (a pending ESC or none)."
  @type t :: %__MODULE__{pending_since: integer() | nil}
  defstruct pending_since: nil

  @type event :: %{key: atom(), mod: :none | :alt | :ctrl, time_ms: integer()}

  @doc "Feed one raw key event; returns {decoded_events, new_state}."
  @spec push(t(), %{key: atom(), time_ms: integer()}) :: {[event()], t()}
  def push(%__MODULE__{pending_since: nil} = st, %{key: :esc} = ev) do
    {[], %{st | pending_since: ev.time_ms}}
  end

  def push(%__MODULE__{pending_since: since}, ev) when not is_nil(since) do
    if ev.time_ms - since <= @esc_window_ms do
      # ESC + key within the window => alt-key
      {[event_from(ev, :alt)], %__MODULE__{}}
    else
      # window expired: ESC was alone; this event is plain
      {[event_from(%{key: :esc, time_ms: since}, :none), event_from(ev, :none)], %__MODULE__{}}
    end
  end

  def push(st, ev) do
    {[event_from(ev, :none)], st}
  end

  @doc """
  Called on timer ticks: if an ESC has been pending longer than the
  window, release it as a lone ESC.
  """
  @spec drain(t(), integer()) :: {[event()], t()}
  def drain(%__MODULE__{pending_since: since} = st, now_ms) when not is_nil(since) do
    if now_ms - since > @esc_window_ms do
      {[event_from(%{key: :esc, time_ms: since}, :none)], %__MODULE__{}}
    else
      {[], st}
    end
  end

  def drain(st, _now), do: {[], st}

  defp event_from(%{key: k, time_ms: t}, mod), do: %{key: k, mod: mod, time_ms: t}
end
