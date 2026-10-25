defmodule CodingAgent.UI.CommandsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Commands
  alias CodingAgent.UI.Menu

  test "every command has unique name, usage and a resolvable parse" do
    names = Enum.map(Commands.all(), & &1.name)
    assert names == Enum.uniq(names)

    for c <- Commands.all() do
      assert c.usage |> String.starts_with?("/" <> c.name)
      assert c.summary != ""
      assert is_atom(c.action)
    end
  end

  test "resolve/1 finds a command by name, nil otherwise" do
    assert %{action: :switch_model} = Commands.resolve("model")
    assert Commands.resolve("nope") == nil
  end

  test "parse/1 splits a command and its args" do
    assert {:command, %{action: :switch_model}, ["gpt"]} = Commands.parse("/model gpt")
    assert {:command, %{action: :quit}, []} = Commands.parse("  /quit  ")
  end

  test "parse/1 leaves non-commands and unknown names as text" do
    assert :text = Commands.parse("hello")
    assert :text = Commands.parse("/")
    assert :text = Commands.parse("/notacommand")
    assert :text = Commands.parse("and/or just text")
  end

  test "filter/1 matches by prefix and by summary, empty lists all" do
    assert length(Commands.filter("")) == length(Commands.all())
    # by NAME prefix (nothing else is named "undo")
    assert Enum.map(Commands.filter("und"), & &1.name) == ["undo"]
    # by SUMMARY substring — "switch session" is in the summary, not the name
    assert "sessions" in Enum.map(Commands.filter("switch session"), & &1.name)
    # the two combine: `mod` prefix-matches `model` AND matches `catalog`'s
    # summary ("refresh the model catalog")
    assert Enum.map(Commands.filter("mod"), & &1.name) == ["model", "catalog"]
    # the first token narrows; the rest is treated as the argument
    assert Enum.map(Commands.filter("model qw"), & &1.name) == ["model"]
  end

  test "the menu is a projection of the registry (ADR 034)" do
    menu_actions = menu_actions()
    registry_actions = Commands.menu_commands() |> Enum.map(& &1.action)

    assert menu_actions == registry_actions

    # fast-path letters are unique across the menu
    keys = Commands.menu_commands() |> Enum.map(& &1.key)
    assert keys == Enum.uniq(keys)
  end

  test "every registry command action is owned by the TUI resolver" do
    # the TUI resolves each action through run_command_action/3; this
    # guards against a record whose action nothing handles
    handled = %{
      :help => :special,
      :new_session => :special,
      :switch_agent => :special,
      :export => :special,
      :undo => :special,
      :compact => :special,
      :show_stats => :special,
      :refresh_catalog => :special,
      :switch_session => :menu,
      :switch_model => :menu,
      :subagents => :menu,
      :toggle_tool_output => :menu,
      :toggle_sidebar => :menu,
      :toggle_debug => :menu,
      :show_keymaps => :menu,
      :quit => :menu
    }

    for c <- Commands.all() do
      assert Map.has_key?(handled, c.action),
             "command #{inspect(c.name)} has action #{inspect(c.action)} nothing handles"
    end
  end

  defp menu_actions do
    Menu.main_menu().items |> Enum.map(& &1.action)
  end
end
