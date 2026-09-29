defmodule CodingAgent.UI.Commands do
  @moduledoc """
  The user-visible command surface as DATA (ADR 034).

  One record per command, and ONE source for three consumers:

    * the `/` palette in the composer (filter + run),
    * the ``ctrl-x`` menu (`CodingAgent.UI.Menu` projects the records
      that declare a fast-path ``key``),
    * the ``/help`` popup and the reference page
      (``docs/source/reference/commands.rst``, checked by a drift test).

  A record is a plain map, no TUI state:

    * ``name``    — typed after ``/`` (lowercase, one word),
    * ``summary`` — what it does,
    * ``usage``   — how to invoke it, arguments included,
    * ``action``  — the TUI action atom ``run_menu_action/2`` resolves,
    * ``key``     — the ``ctrl-x`` fast-path letter, or ``nil``,
    * ``arg``     — ``:none`` | ``:optional`` | ``:required`` (a trailing
      token; the command opens its popup when the argument is absent and
      the action supports one).

  The registry is pure; it does not know about sessions, the store or
  providers. It answers "what can the human type" and "what action does
  it mean"; the TUI owns what the action DOES.
  """

  @typedoc "How a command takes a trailing argument."
  @type arg_mode :: :none | :optional | :required

  @typedoc "One command record."
  @type t :: %{
          name: String.t(),
          summary: String.t(),
          usage: String.t(),
          action: atom(),
          key: String.t() | nil,
          arg: arg_mode()
        }

  @doc "Every command, in presentation order."
  @spec all() :: [t()]
  def all do
    [
      cmd("help", "show all commands", "/help", :help, key: "h"),
      cmd("new", "start a fresh session", "/new", :new_session),
      cmd("sessions", "switch session", "/sessions", :switch_session, key: "s"),
      cmd("model", "switch model", "/model [name]", :switch_model, key: "m", arg: :optional),
      cmd("agent", "switch agent", "/agent [name]", :switch_agent, arg: :optional),
      cmd("export", "export this session", "/export [md|json]", :export, arg: :optional),
      cmd("subagents", "subagents", "/subagents", :subagents, key: "a"),
      cmd("tools", "toggle tool output", "/tools", :toggle_tool_output, key: "t"),
      cmd("sidebar", "toggle sidebar", "/sidebar", :toggle_sidebar, key: "p"),
      cmd("debug", "toggle debug line", "/debug", :toggle_debug, key: "d"),
      cmd("keymaps", "show keymaps", "/keymaps", :show_keymaps, key: "k"),
      cmd("quit", "quit", "/quit", :quit, key: "q")
    ]
  end

  defp cmd(name, summary, usage, action, opts \\ []) do
    %{
      name: name,
      summary: summary,
      usage: usage,
      action: action,
      key: Keyword.get(opts, :key),
      arg: Keyword.get(opts, :arg, :none)
    }
  end

  @doc "The command named `name`, or nil."
  @spec resolve(String.t()) :: t() | nil
  def resolve(name) when is_binary(name), do: Enum.find(all(), &(&1.name == name))

  @doc """
  Commands whose name or summary contains `query` (case-insensitive). The
  empty query lists everything. Only the first token is matched by NAME,
  so ``/model qw`` still offers ``model`` (the rest is its argument).
  """
  @spec filter(String.t()) :: [t()]
  def filter(query) do
    q = query |> String.trim() |> String.downcase()
    name_token = q |> String.split(" ", parts: 2) |> hd()

    Enum.filter(all(), fn c ->
      q == "" or String.starts_with?(c.name, name_token) or String.contains?(c.summary, q)
    end)
  end

  @doc """
  Parses a composer input as a command invocation.

  Returns ``{:command, record, args}`` when the trimmed input starts with
  ``/`` and names a known command (``args`` is the rest, split on
  whitespace), else ``:text``. A lone ``/`` or an unknown name is
  ``:text`` — the input stays a normal message rather than vanishing.
  """
  @spec parse(String.t()) :: {:command, t(), [String.t()]} | :text
  def parse(input) when is_binary(input) do
    trimmed = String.trim(input)

    with "/" <> rest <- trimmed,
         [name | args] <- String.split(rest, ~r/\s+/, trim: true),
         %{} = record <- resolve(name) do
      {:command, record, args}
    else
      _ -> :text
    end
  end

  @doc """
  The command rows for the ``ctrl-x`` menu (records with a fast-path
  letter), in registry order. ``UI.Menu`` projects these into items so the
  menu and the palette cannot disagree.
  """
  @spec menu_commands() :: [t()]
  def menu_commands, do: Enum.filter(all(), &(&1.key != nil))

  @doc "The usage lines for ``/help``, one per command."
  @spec help_lines() :: [String.t()]
  def help_lines, do: Enum.map(all(), &(&1.usage <> "  —  " <> &1.summary))
end
