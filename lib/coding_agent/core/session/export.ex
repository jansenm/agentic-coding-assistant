# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Session.Export do
  @moduledoc """
  Export a session as a portable, *readable* artifact (ADR 020 ``S3``).

  Scope, decided deliberately: the export is the **display view** — what
  the user saw, including reasoning and tool results with their
  arguments — plus redacted session metadata. It is a transcript to hand
  to a human or another agent, **not a resumable session**: the agent
  view is not exported, because it is ReqLLM wire data whose round-trip
  needs a hand-written exactness encoder (ADR 020 rejected that cost),
  and it is only meaningful to this harness anyway.

  Redaction is part of export: `provider_config` (user-written connection
  info) is never included. What is written is plain text and JSON — no
  `term_to_binary`, so an exported file carries none of the
  atom-exhaustion risk of an imported binary blob.
  """

  alias CodingAgent.Core.Session.Store

  @type data :: %{
          id: String.t(),
          model: String.t() | nil,
          status: atom(),
          scope_root: String.t() | nil,
          saved_at: DateTime.t(),
          size: non_neg_integer(),
          entries: [map()]
        }

  @doc """
  Collects an exportable snapshot of a session: redacted metadata plus
  the display view (oldest first). `{:error, :enoent}` when there is no
  such session.
  """
  @spec data(String.t()) :: {:ok, data()} | {:error, term()}
  def data(id) do
    case Enum.find(Store.list(), &(&1.id == id)) do
      nil ->
        {:error, :enoent}

      meta ->
        {:ok,
         %{
           id: meta.id,
           model: meta.model,
           status: meta.status,
           scope_root: meta.scope_root,
           saved_at: meta.saved_at,
           size: meta.size,
           # NOTE: no provider_config, no policy — nothing that could
           # carry a secret or a machine-specific path beyond the scope.
           entries: Store.display(id)
         }}
    end
  end

  @doc "Renders a snapshot as JSON (a portable document)."
  @spec to_json(data()) :: String.t()
  def to_json(data) do
    data
    |> Map.update!(:saved_at, &DateTime.to_iso8601/1)
    |> Map.update!(:status, &to_string/1)
    |> Map.update!(:entries, fn entries -> Enum.map(entries, &json_entry/1) end)
    |> Jason.encode!(pretty: true)
  end

  @doc "Renders a snapshot as Markdown (readable, greppable, diffable)."
  @spec to_markdown(data()) :: String.t()
  def to_markdown(data) do
    header(data) <> "\n" <> Enum.map_join(data.entries, "\n", &markdown_entry/1)
  end

  # -- JSON --------------------------------------------------------------------

  defp json_entry(%{kind: :tool, meta: {:tool, name, args}} = e) do
    base_entry(e) |> Map.put(:tool, name) |> Map.put(:arguments, args)
  end

  defp json_entry(%{kind: :tool, meta: {:tool, name}} = e) do
    base_entry(e) |> Map.put(:tool, name) |> Map.put(:arguments, %{})
  end

  defp json_entry(e), do: base_entry(e)

  defp base_entry(e) do
    %{seq: e.seq, kind: to_string(e.kind), text: e.text}
    |> put_if(e.agent, :agent)
  end

  defp put_if(map, nil, _key), do: map
  defp put_if(map, value, key), do: Map.put(map, key, value)

  # -- Markdown ----------------------------------------------------------------

  defp header(data) do
    """
    # Session #{data.id}

    - model: #{data.model}
    - status: #{data.status}
    - scope: #{data.scope_root}
    - saved: #{DateTime.to_iso8601(data.saved_at)}
    - exported: #{DateTime.to_iso8601(DateTime.utc_now())}

    > Transcript exported from the display view. This is a readable
    > record, not a resumable session.
    """
  end

  defp markdown_entry(%{kind: :user, text: t}), do: "## user\n\n#{t}\n"

  defp markdown_entry(%{kind: :assistant, text: t, agent: agent}) do
    "## assistant#{agent_suffix(agent)}\n\n#{t}\n"
  end

  defp markdown_entry(%{kind: :reasoning, text: t}), do: "### reasoning\n\n#{t}\n"

  defp markdown_entry(%{kind: :info, text: t}), do: "<!-- info: #{t} -->\n"

  defp markdown_entry(%{kind: :summary, text: t}), do: "## context summary\n\n#{t}\n"

  defp markdown_entry(%{kind: :tool, text: t, meta: {:tool, name, args}}) do
    "### tool: #{name}\n\n```json\n#{Jason.encode!(args, pretty: true)}\n```\n\n" <>
      "```\n#{t}\n```\n"
  end

  defp markdown_entry(%{kind: :tool, text: t, meta: {:tool, name}}) do
    "### tool: #{name}\n\n```\n#{t}\n```\n"
  end

  defp markdown_entry(%{kind: :tool, text: t}), do: "### tool\n\n```\n#{t}\n```\n"
  defp markdown_entry(%{text: t}), do: t <> "\n"

  defp agent_suffix(nil), do: ""
  defp agent_suffix(agent), do: " (#{agent})"
end
