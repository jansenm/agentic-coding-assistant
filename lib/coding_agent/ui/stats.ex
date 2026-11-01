defmodule CodingAgent.UI.Stats do
  @moduledoc """
  The `/stats` snapshot: where a session's time and money went.

  This is a DETAIL view of the same facts the sidebar shows at a glance,
  so it reads the same two mirrors the panel does — the session's
  `Timing` and its `Usage` — and never `Session.state/1`: a turn runs in a
  worker with its own copy, so the session process still holds the state
  the turn STARTED from, and asking it showed a running turn's stats as
  zeros until the turn returned (measured).

  The snapshot is built once per open; reopening refreshes it.

  ## The two ways out (P37)

  `write_file/2` is the guarantee, `copy/2` the convenience:

    * a file beside `tui.log`, in the state dir — the place
      `Core.Config` already documents as "logs and other non-session
      state", so the path in the status line is one the reader can open,
      tail and paste from;
    * OSC 52 to the terminal's clipboard, written to `/dev/tty` the way
      `Mix.Tasks.Tui.reset_terminal/0` writes its sequences, because
      stdout belongs to the renderer. Best effort by nature: tmux needs
      `set-clipboard on` and some terminals ignore the sequence, which is
      exactly why the file exists.

  Nothing here paints: the popup that shows these lines is the TUI's.
  """

  alias CodingAgent.Core.Session.{Timing, Usage}
  alias CodingAgent.UI.Format

  @type t :: %__MODULE__{
          session_id: String.t(),
          timing: Timing.t(),
          usage: Usage.t(),
          trailer: {non_neg_integer(), pos_integer()} | nil
        }

  defstruct session_id: "", timing: nil, usage: nil, trailer: nil

  @doc "Builds the snapshot from the values the TUI mirrors."
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(
      __MODULE__,
      Keyword.merge([timing: Timing.new(), usage: Usage.new()], opts)
    )
  end

  @doc """
  The body: one label/value row per fact, padded to the widest label.

  `llm` and `tools` are the two halves of a round (see
  `Core.Session.Timing`); the per-round average is what makes 33 minutes
  legible — 200 rounds at 9 s is the provider, 200 at 9 s with 8 s in the
  tools is the harness.
  """
  @spec lines(t()) :: [String.t()]
  def lines(%__MODULE__{} = stats) do
    timing = stats.timing
    usage = stats.usage
    avg = fn ms -> Timing.format_ms(Timing.per_round(ms, timing)) end

    [
      stat("session", to_string(stats.session_id)),
      stat("rounds", "#{timing.rounds} calls"),
      stat("llm", "#{Timing.format_ms(timing.llm_ms)}  (#{avg.(timing.llm_ms)}/round)"),
      stat("tools", "#{Timing.format_ms(timing.tool_ms)}  (#{avg.(timing.tool_ms)}/round)"),
      stat(
        "turn",
        "#{timing.turn_rounds} calls  #{Timing.format_ms(timing.turn_llm_ms + timing.turn_tool_ms)}"
      )
    ] ++
      token_lines(usage) ++
      trailer_lines(stats.trailer) ++
      money_lines(usage)
  end

  defp stat(label, value), do: " " <> String.pad_trailing(label, 9) <> value

  # The per-request state trailer against its cap (ADR 024, 2026-11-01).
  # It is the one number that is a BUDGET rather than a total: the trailer
  # is re-sent uncached on every round, so its size is a per-round floor,
  # and the todo list is the only block the model sizes. No row before the
  # first request — a "0" would claim a measurement that has not happened
  # (the same rule as the cached-tokens row).
  defp trailer_lines(nil), do: []

  defp trailer_lines({0, _max}), do: []

  defp trailer_lines({bytes, max}),
    do: [stat("trailer", "#{Format.k(bytes)} of #{Format.k(max)}")]

  defp token_lines(usage) do
    cached =
      case Usage.cached_tokens(usage) do
        0 -> ""
        n -> "  ·  #{Format.k(n)} cached#{hit_suffix(usage)}"
      end

    [
      stat(
        "tokens",
        "#{Format.k(Usage.input_tokens(usage))} in#{cached}  ·  " <>
          "#{Format.k(Usage.output_tokens(usage))} out"
      )
    ]
  end

  defp hit_suffix(usage) do
    case Usage.cache_hit_ratio(usage) do
      nil -> ""
      ratio -> " (#{round(ratio * 100)}%)"
    end
  end

  defp money_lines(usage) do
    usage |> Format.money_rows() |> Enum.map(fn {label, value} -> stat(label, value) end)
  end

  @doc """
  Writes `text` to `<state_dir>/stats-<session>.txt` — the path named in
  the status line. The state dir is where `tui.log` already lives, so the
  reader can open, tail and paste from the same place.
  """
  @spec write_file(String.t(), String.t()) :: {:ok, String.t()} | :error
  def write_file(session_id, text) do
    path = Path.join(CodingAgent.Core.Config.state_dir(), "stats-#{session_id}.txt")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, text) do
      {:ok, path}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  OSC 52 on the controlling tty: `ESC ] 52 ; c ; <base64> BEL`.

  Skipped under `test_mode` — the suite runs on a real tty and must not put
  a base64 snapshot on whoever is running it.
  """
  @spec copy(String.t(), boolean()) :: :ok
  def copy(_text, true), do: :ok

  def copy(text, _test_mode?) do
    payload = Base.encode64(text)

    case File.open("/dev/tty", [:write, :raw]) do
      {:ok, tty} ->
        IO.binwrite(tty, "\e]52;c;#{payload}\a")
        File.close(tty)

      {:error, _} ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
