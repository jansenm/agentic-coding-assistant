defmodule CodingAgent.Core.Text do
  @moduledoc """
  The one UTF-8 hygiene point (ADR 008).

  Tool output, restored contexts and provider text are arbitrary bytes;
  a single invalid byte in the context makes EVERY later request fail to
  JSON-encode ("invalid byte 0x83"), which the UI then reports as
  "provider down". That is a poisoned context, not a provider problem,
  and it is permanent unless the byte is replaced.

  `scrub/1` swaps each invalid byte for U+FFFD, preserving the readable
  parts. This is the PREVENT side; sessions persisted before the guard
  existed also need the HEAL side (`Session.sanitize_context/1`).
  """

  @doc """
  Returns `text` unchanged when it is valid UTF-8, otherwise replaces
  each invalid byte with U+FFFD.
  """
  @spec scrub(binary()) :: binary()
  def scrub(text) when is_binary(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text)
  end

  @doc """
  Renders arbitrary tool output as scrubbed text: a binary passes
  through, anything else is inspected (capped) — never `inspect/1` on a
  large term without a limit.
  """
  @spec to_text(term()) :: String.t()
  def to_text(output) when is_binary(output), do: scrub(output)
  def to_text(output), do: inspect(output, pretty: true, limit: 100) |> scrub()
end
