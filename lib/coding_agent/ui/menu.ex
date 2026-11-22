# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.UI.Menu do
  @moduledoc """
  Command menus as DATA (extends ADR 011's keymap-as-data discipline to
  menus).

  The command table is ``CodingAgent.UI.Commands`` (ADR 034) — the ONE
  registry. This module only PROJECTS it into menu items, so the
  ``ctrl-x`` menu and the ``/`` palette can never disagree about what a
  command is.

  One prefix chord (`ctrl-x` in v1) starts a menu interaction. Two
  outcomes, distinguished by timing:

  - a following letter within ~1s fires that item DIRECTLY (no popup —
    the ctrl-x-style fast path);
  - the timeout shows the POPUP instead (navigate with arrows, enter
    picks) — the ctrl-p-style menu.

  Items come from the registry records that declare a fast-path ``key``.
  """

  alias CodingAgent.UI.Commands

  @typedoc "One menu item: action + presentation + behavior."
  @type item :: %{
          action: atom(),
          key: String.t(),
          label: String.t(),
          # which popup lists this item (nil = fires on the prefix only)
          menu: atom() | nil,
          # true = the item needs a second-choice popup of its own
          needs_popup: boolean()
        }

  @typedoc "A menu definition: id + items."
  @type t :: %{id: atom(), items: [item()], title: String.t()}

  # Actions whose target list is a TUI-owned popup (the session list, the
  # model list, the subagent tabs). The menu opens that popup instead of
  # running the action inline.
  @popup_actions [:switch_session, :switch_model, :subagents]

  @doc "The command table, projected to menu items (ADR 034)."
  @spec commands() :: [item()]
  def commands do
    Enum.map(Commands.menu_commands(), fn c ->
      %{
        action: c.action,
        key: c.key,
        label: c.summary,
        menu: :main,
        needs_popup: c.action in @popup_actions
      }
    end)
  end

  @doc "The menu definition the prefix chord opens."
  @spec main_menu() :: t()
  def main_menu do
    %{
      id: :main,
      title: " commands  (letter=run, arrows/enter=navigate)",
      items: Enum.filter(commands(), &(&1.menu == :main))
    }
  end

  @doc "Resolve a pressed letter against a menu: the item or nil."
  @spec resolve(t(), String.t()) :: item() | nil
  def resolve(menu, key) do
    Enum.find(menu.items, &(&1.key == key))
  end

  @doc "Fires an item directly from the prefix (fast path, no popup)."
  @spec fast_path(item()) ::
          {:run, atom()} | {:popup, t()} | :none
  def fast_path(item) do
    cond do
      item.needs_popup -> {:popup, popup_menu_for(item)}
      true -> {:run, item.action}
    end
  end

  # Items needing a popup open THEIR popup (e.g. switch_session opens
  # the session list). The popup menu carries the original action so
  # the TUI knows what to do with the selection.
  defp popup_menu_for(item) do
    %{id: item.action, title: " #{item.label}  (arrows, enter=pick, esc=cancel)", items: [item]}
  end

  @doc "The keys shown in the popup navigation line."
  @spec keys_hint() :: String.t()
  def keys_hint, do: "↑/↓ move · enter run · esc cancel"
end
