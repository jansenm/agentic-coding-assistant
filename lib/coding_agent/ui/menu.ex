defmodule CodingAgent.UI.Menu do
  @moduledoc """
  Command menus as DATA (extends ADR 011's keymap-as-data discipline to
  menus).

  One prefix chord (`ctrl-x` in v1) starts a menu interaction. Two
  outcomes, distinguished by timing:

  - a following letter within ~1s fires that item DIRECTLY (no popup —
    the ctrl-x-style fast path);
  - the timeout shows the POPUP instead (navigate with arrows, enter
    picks) — the ctrl-p-style menu.

  Menus are views over one command table: each item declares which
  menu it belongs to, so the table can grow without cramming
  everything into one popup (the owner's objection to opencode's
  single menu).
  """

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

  # -- Command table ----------------------------------------------------------
  # v1: switch session (the working item), keys/help. The fast-path
  # letter is unique per menu — one table, one prefix for now.
  @spec commands() :: [item()]
  def commands do
    [
      %{
        action: :switch_session,
        key: "s",
        label: "switch session",
        menu: :main,
        needs_popup: true
      },
      %{
        action: :toggle_tool_output,
        key: "t",
        label: "toggle tool output",
        menu: :main,
        needs_popup: false
      },
      %{
        action: :show_keymaps,
        key: "k",
        label: "show keymaps",
        menu: :main,
        needs_popup: false
      },
      %{
        action: :quit,
        key: "q",
        label: "quit",
        menu: :main,
        needs_popup: false
      }
    ]
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
