# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.Format do
  @moduledoc """
  How a NUMBER is spelled, for every surface that shows one.

  Two panels describe the same session — the sidebar (glance) and the
  `/stats` popup (detail) — and before this module each had its own copy
  of the token abbreviation and the money rule: the same cost printed
  `$0.0040` in one and `$0.004` in the other as soon as one was edited.
  Formatting is not painting, so it does not live in a region module:
  `UI.Sidebar` and `UI.Tui`'s stats popup both read from here, and a
  third reader (an export, a future panel) gets the same spelling.
  """

  @doc """
  A token count, abbreviated to fit a narrow column: `123`, `12.3k`,
  `29.0M` — one decimal, so two counts of the same magnitude stay
  comparable by column.
  """
  @spec k(number()) :: String.t()
  def k(n) when n < 1_000, do: "#{n}"
  def k(n) when n < 1_000_000, do: "#{trunc(n / 100) / 10}k"
  def k(n), do: "#{trunc(n / 100_000) / 10}M"

  @doc """
  A money amount. Sub-cent amounts are the interesting ones here (a
  cached 200k call is $0.004), so the precision follows the magnitude
  instead of a fixed four decimals that would print "$0.0000" for a real
  cost.
  """
  @spec money(number()) :: String.t()
  def money(n) do
    decimals = if n < 0.01, do: 5, else: if(n < 1, do: 4, else: 2)
    "$" <> :erlang.float_to_binary(n * 1.0, decimals: decimals)
  end

  @doc """
  The money rows: what was spent and what is left, or nothing at all.

  A cost of 0 means "no baseline yet" (the first account sample only
  re-bases), so it is not shown — no surface claims a measured zero.
  `(billed)` marks a DELTA of the provider's own account figure; without
  it the number came priced with the response.
  """
  @spec money_rows(map()) :: [{String.t(), String.t()}]
  def money_rows(usage) do
    spent =
      case usage.cost do
        c when is_number(c) and c > 0 ->
          [{"cost", money(c) <> basis_suffix(usage.cost_basis)}]

        _ ->
          []
      end

    left =
      case usage.balance do
        %{remaining: r} = b when is_number(r) ->
          [{"credits", money(r) <> allowance_suffix(b)}]

        _ ->
          []
      end

    spent ++ left
  end

  defp basis_suffix(:billed), do: " (billed)"
  defp basis_suffix(_), do: ""

  defp allowance_suffix(%{allowance: a}) when is_number(a) and a > 0, do: " / #{money(a)}"
  defp allowance_suffix(_), do: ""

  @doc """
  The reasoning-effort label (ADR 029). The session stores req_llm's
  canonical atom; `nil` means no override on the wire, which reads as
  "default" (the provider's own default).
  """
  @spec effort_name(atom() | String.t() | nil) :: String.t()
  def effort_name(nil), do: "default"
  def effort_name(effort) when is_atom(effort), do: Atom.to_string(effort)
  def effort_name(effort), do: to_string(effort)
end
