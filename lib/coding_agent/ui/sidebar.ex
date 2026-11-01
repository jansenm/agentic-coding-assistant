defmodule CodingAgent.UI.Sidebar do
  @moduledoc """
  The left panel: the session at a glance.

  This module owns the panel's look and its row ORDER. The TUI hands it a
  struct of already-resolved values (`new/1`) and paints the single widget
  it returns — nothing here reads the session, the config or the clock, so
  the panel can be rendered and asserted without a TUI.

  ## What the panel answers, and in that order

  The rows are ordered by the question a reader asks them, not by which
  number arrived first:

    * **where am I** — the scope heading (the repo basename), a body line
      in `:emphasis` rather than a `Block` title: a one-sided border paints
      a title one cell in from the edge, which reads as neither heading nor
      content;
    * **what is doing the work** — the agent (running/next split while a
      turn is in flight), the model and provider it runs on, and the
      session id;
    * **what is live right now** — the running subagents, then the model's
      own todo list. These are the two blocks that CHANGE while you work,
      so they sit above the figures: a session that spends a turn watching
      a delegation wants that above the token counters, not below a wall of
      numbers that only move at a round boundary;
    * **what it has cost so far** — the effort knob together with the token
      and context rows it belongs with, the round timing, the catalog's
      age, and the money. Reference figures: they are read, not acted on;
    * **how to drive it** — the key hints, last, because they are only
      needed until they are learned.

  ## Two lists, not one

  The identity and the figures are separate `Styles.definition_list/2`
  calls on purpose: that function pads to the widest label of ITS list, so
  the identity block pads to `provider` (8) and the figures block to
  `tokens out` (10). One list would pad every identity row to accommodate
  a figure.

  The blocks that are absent say nothing at all — no subagents, no todos,
  no money, no catalog row means no gap and no header, so a fresh session
  is a short panel rather than an empty scaffold.
  """

  alias CodingAgent.Core.Providers.Catalog
  alias CodingAgent.Core.Session.Timing
  alias CodingAgent.Core.Session.Usage
  alias CodingAgent.UI.{Format, Styles}
  alias ExRatatui.Widgets.Paragraph

  # The panel's own width. It is a fact of the LAYOUT as much as of the
  # panel (the frame reserves exactly this many columns), so the TUI
  # passes it in and nothing here guesses.
  @default_width 36

  # The caps: the panel's height stays bounded however much a session
  # delegates or plans. Overflow is named, never silently dropped.
  @todo_cap 8
  @subagent_cap 8

  @type t :: %__MODULE__{
          scope_root: String.t() | nil,
          session_id: String.t(),
          running_agent: String.t() | nil,
          next_agent: String.t() | nil,
          busy?: boolean(),
          model: String.t() | nil,
          effort: atom() | String.t() | nil,
          usage: Usage.t(),
          window: non_neg_integer(),
          soft: non_neg_integer(),
          hard: non_neg_integer(),
          window_source: atom() | nil,
          last_round: Timing.round() | nil,
          todos: [map()],
          subagents: %{optional(String.t()) => map()},
          active_tab: String.t() | nil,
          width: pos_integer()
        }

  defstruct scope_root: nil,
            session_id: "",
            running_agent: nil,
            next_agent: nil,
            busy?: false,
            model: nil,
            effort: nil,
            usage: nil,
            window: 0,
            soft: 0,
            hard: 0,
            window_source: nil,
            last_round: nil,
            todos: [],
            subagents: %{},
            active_tab: nil,
            width: @default_width

  @doc "Builds the panel from resolved values (see the moduledoc)."
  @spec new(keyword()) :: t()
  def new(opts) do
    opts
    |> Keyword.put_new(:usage, Usage.new())
    |> then(&struct!(__MODULE__, &1))
  end

  @doc """
  The panel as one widget: a borderless `Paragraph` carrying the sidebar
  fill over its whole rect.

  NO title and no border — the heading is the first BODY line, and the
  fill against the transcript's background is the separation (a `[:right]`
  rule draws a column the fill already draws).
  """
  @spec widget(t()) :: Paragraph.t()
  def widget(%__MODULE__{} = panel) do
    %Paragraph{
      text: lines(panel),
      # the whole panel carries the fill, so the gaps between role-styled
      # spans are filled too (a patchy fill looked broken)
      style: Styles.surface(:sidebar),
      block: Styles.panel(borders: [], surface: :sidebar)
    }
  end

  @doc """
  The panel's lines, top to bottom. Public so a test can assert the order
  without a terminal (the rendered widget's `text` is the same list).
  """
  @spec lines(t()) :: [ExRatatui.Text.Line.t()]
  def lines(%__MODULE__{} = panel) do
    [Styles.heading(scope_name(panel.scope_root), :sidebar), Styles.gap()] ++
      Styles.definition_list(identity(panel), :sidebar) ++
      subagent_section(panel) ++
      todo_section(panel) ++
      [Styles.gap()] ++
      Styles.definition_list(figures(panel), :sidebar) ++
      money_section(panel) ++
      help()
  end

  # -- identity: who is doing the work ---------------------------------------

  defp identity(panel) do
    agent_rows(panel.running_agent, panel.next_agent, panel.busy?) ++
      model_rows(panel.model) ++
      [{"session", String.slice(panel.session_id, 0, 22)}]
  end

  # While a turn is IN FLIGHT, running and next are BOTH shown so they can
  # differ (Tab only changes the next turn's agent); when idle only the
  # next agent is shown, because `running_agent` keeps the last turn's
  # value. The value carries the `:agent` role so the identity keeps the
  # colour the badge gave it.
  defp agent_rows(running, next_agent, busy?) do
    cond do
      not busy? ->
        [{"agent", next_agent, :agent}]

      is_binary(running) and is_binary(next_agent) and running != next_agent ->
        [
          {"agent", "#{running} running", :agent},
          {"agent", "#{next_agent} next", :agent}
        ]

      is_binary(running) ->
        [{"agent", "#{running} running", :agent}]

      is_binary(next_agent) ->
        [{"agent", "#{next_agent} next", :agent}]

      true ->
        [{"agent", nil, :agent}]
    end
  end

  # The model spec's two halves on their own rows. A spec is
  # "<provider>:<model id>" and it used to be ONE 32-char-clipped badge
  # ("model ollama_cloud:deepseek-v4.1-fl…") — the version that
  # distinguishes one model from another was exactly what got cut. Split,
  # both halves fit whole. The split rule is the one `Request.build/2` and
  # `ProviderHealth.probe_model/2` use, so the panel names the same two
  # things the wire request does. A spec with no colon names no provider:
  # the `provider` row is omitted rather than filled with a guess.
  defp model_rows(model) do
    case split_model_spec(model) do
      {id, nil} -> [{"model", id, :model}]
      {id, provider} -> [{"model", id, :model}, {"provider", provider, :model}]
    end
  end

  @doc false
  def split_model_spec(model) when is_binary(model) and model != "" do
    case String.split(model, ":", parts: 2) do
      [provider, id] -> {id, provider}
      [id] -> {id, nil}
    end
  end

  def split_model_spec(_), do: {nil, nil}

  # -- live: what is happening now -------------------------------------------

  # The ACTIVE `task` children only (ADR 018): a finished child's tab is
  # kept (read-only) but it is no longer "what is happening", and listing
  # every delegation a session ever ran would grow the panel without
  # bound. The active TAB is marked so the panel and the transcript agree
  # on which view the human is in.
  defp subagent_section(panel) do
    running =
      panel.subagents
      |> Enum.reject(fn {_id, c} -> Map.get(c, :finished?, false) end)
      |> Enum.sort_by(fn {_id, c} -> Map.get(c, :agent) end)

    case running do
      [] ->
        []

      _ ->
        shown = Enum.take(running, @subagent_cap)
        hidden = length(running) - length(shown)

        [Styles.gap(), Styles.section_header("subagents", :sidebar)] ++
          Enum.map(shown, fn {id, c} ->
            Styles.subagent_line(
              Map.get(c, :agent),
              Map.get(c, :model),
              id == panel.active_tab,
              panel.width - 4,
              :sidebar
            )
          end) ++
          if hidden > 0, do: [Styles.section_header("… +#{hidden} more", :sidebar)], else: []
    end
  end

  # The model's own list (ADR 031): a gap, a muted header, one row per
  # item. Empty when there is no list, so a session that never plans gains
  # no chrome.
  defp todo_section(%__MODULE__{todos: []}), do: []

  defp todo_section(%__MODULE__{todos: todos} = panel) when is_list(todos) do
    shown = Enum.take(todos, @todo_cap)

    overflow =
      case length(todos) - @todo_cap do
        n when n > 0 -> [Styles.section_header("… +#{n} more", :sidebar)]
        _ -> []
      end

    [Styles.gap(), Styles.section_header("todo", :sidebar)] ++
      Styles.todo_lines(shown, panel.width - 4, :sidebar) ++ overflow
  end

  defp todo_section(%__MODULE__{}), do: []

  # -- figures: what it has cost so far --------------------------------------

  defp figures(panel) do
    usage = panel.usage
    last_in = Usage.last_input_tokens(usage)
    pct = trunc(last_in * 100 / max(panel.window, 1))

    # pre-compaction notice territory: the Compactor's warn threshold
    pct_role = if last_in >= trunc(panel.soft * 0.8), do: :warning, else: :text

    # An uncataloged model's window is the 500k default: a guess. Mark the
    # soft line so it cannot be mistaken for a verified one (the session
    # also emits a once-per-session note; this is the always-visible cue).
    fallback? = panel.window_source == :fallback
    soft_suffix = if fallback?, do: " tok (assumed)", else: " tok"
    soft_role = if fallback?, do: :warning, else: pct_role

    [
      {"effort", Format.effort_name(panel.effort)},
      {"tokens in", {:decimal, Format.k(Usage.input_tokens(usage)), nil}}
    ] ++
      cached_rows(usage) ++
      [
        {"tokens out", {:decimal, Format.k(Usage.output_tokens(usage)), nil}},
        {"context", {:decimal, Format.k(last_in), " (#{pct}% win)"}, pct_role},
        {"soft at", {:decimal, Format.k(panel.soft), soft_suffix}, soft_role},
        {"hard at", {:decimal, Format.k(panel.hard), " tok"}, pct_role}
      ] ++
      last_round_row(panel.last_round) ++
      catalog_row(panel.window_source, fallback?)
  end

  # The prompt-cache row, or nothing at all. Zero means "no hit or the
  # provider does not report caching" — indistinguishable, so the row stays
  # hidden instead of claiming a measured 0 %. The percentage comes from
  # `Usage.cache_hit_ratio/1`, which is nil when the provider reports
  # cached tokens outside the input (Anthropic); there the count is still
  # worth showing, the share is not derivable.
  defp cached_rows(usage) do
    case Usage.cached_tokens(usage) do
      0 ->
        []

      cached ->
        suffix =
          case Usage.cache_hit_ratio(usage) do
            nil -> nil
            ratio -> " (#{round(ratio * 100)}% hit)"
          end

        [{"cached in", {:decimal, Format.k(cached), suffix}}]
    end
  end

  # The last finished round's two durations (I1): the provider call and the
  # work it caused, in that order — the same order `/stats` uses, and the
  # same number it averages. Absent until this view has seen a round
  # finish (a freshly attached session shows no row until its next one).
  defp last_round_row(nil), do: []

  defp last_round_row(round) do
    [{"last round", "#{Timing.format_ms(round.llm_ms)} + #{Timing.format_ms(round.tool_ms)}"}]
  end

  # Which data the window was resolved against, and how old it is. The
  # snapshot is a PACKAGED file cut on llm_db's release cadence, so it is
  # routinely months behind the providers: a cloud model released since the
  # cut is absent from it and gets the 500k guess. Without the date the
  # guess looks arbitrary; with it, `assumed` beside `2026-08-23 (55d)` IS
  # the explanation. The role says whether that answer was USED:
  # `:warning` when the catalog was consulted and did not know the model,
  # `:muted` when it answered. Absent in the two states where there is
  # nothing to date — a `:configured` window never consulted it, and
  # `:loading` has not finished loading it.
  defp catalog_row(source, _fallback?) when source in [nil, :configured, :loading], do: []

  defp catalog_row(_source, fallback?) do
    [{"catalog", Catalog.snapshot_age(), if(fallback?, do: :warning, else: :muted)}]
  end

  # What the provider says was spent — never tokens × a local rate. Both
  # rows are absent until there is something to say: a fresh session has a
  # baseline, not a cost. A cost of 0 is not shown at all (`Format`).
  defp money_section(panel) do
    case Format.money_rows(panel.usage) do
      [] -> []
      rows -> Styles.definition_list(rows, :sidebar)
    end
  end

  # -- the heading and the hints ---------------------------------------------

  # The repo this session is scoped to, as its last path segment (the full
  # path is far wider than the panel). A scope with no basename ("/") or no
  # scope at all (a half-built state) falls back to something printable
  # rather than a blank heading.
  defp scope_name(root) when is_binary(root) and root != "" do
    case Path.basename(root) do
      "" -> root
      name -> name
    end
  end

  defp scope_name(_), do: "—"

  defp help do
    [
      Styles.gap(),
      Styles.section_header("ctrl-t toggles tools", :sidebar),
      Styles.section_header("ctrl-x p hides panel", :sidebar)
    ]
  end
end
