defmodule CodingAgent.Docs.ConfigReferenceTest do
  @moduledoc """
  The configuration reference is checked against the code (ADR 008: one
  boundary; a documented knob that changes nothing is a lie, and a knob
  that changes something but is undocumented is a trap).

  Forward direction only, deliberately: every configuration key the code
  actually reads must appear in ``docs/source/reference/configuration.rst``.
  A new knob added to ``Core.Config`` (or a new agent frontmatter field)
  without a reference entry fails this test. The reverse (a documented key
  that nothing reads) is caught by the reference's own prose review — the
  scan below cannot distinguish a stale row from a table header.
  """
  use ExUnit.Case, async: true

  @reference "docs/source/reference/configuration.rst"

  setup_all do
    doc = File.read!(Path.expand(@reference, File.cwd!()))
    %{doc: doc}
  end

  test "every config.toml key the code reads is documented", %{doc: doc} do
    keys = scan(lib_sources(), ~r/config\["([a-z_]+)"\]/)
    assert keys != []

    for key <- keys do
      assert String.contains?(doc, "``#{key}``"),
             "config.toml key #{inspect(key)} is read in lib/ but missing from #{@reference}"
    end
  end

  test "every configured_count key is documented", %{doc: doc} do
    # the layered non-negative-integer accessors pass their key as the
    # second argument, so the literal is not inside `config[...]`
    keys = scan(lib_sources(), ~r/configured_count\([^,]+,\s*"([a-z_]+)"\)/)

    for key <- keys do
      assert String.contains?(doc, "``#{key}``"),
             "config.toml key #{inspect(key)} is read in lib/ but missing from #{@reference}"
    end
  end

  test "every app-env runtime knob is documented", %{doc: doc} do
    source = File.read!(Path.expand("lib/coding_agent/core/config.ex", File.cwd!()))
    keys = scan([source], ~r/app\(:([a-z_]+)/)

    # a knob may be documented in its config.toml form (``key``) or its
    # app-env colon form (``:key``); either satisfies the surface
    for key <- keys do
      assert String.contains?(doc, "``#{key}``") or String.contains?(doc, "``:#{key}``"),
             "app-env key #{inspect(key)} is read in Config but missing from #{@reference}"
    end
  end

  test "every agent frontmatter field is documented", %{doc: doc} do
    source =
      File.read!(Path.expand("lib/coding_agent/core/agent/frontmatter.ex", File.cwd!()))

    # only the `build/2` struct fields, not the helper call sites
    build = source |> String.split("defp build(map, body)") |> List.last()

    fields =
      scan(
        [build],
        ~r/\b(?:str|str_list|number|pos_int|permission)\((?:map\[|map\.)?"([A-Za-z_]+)"/
      )

    assert fields != []

    for field <- fields do
      assert String.contains?(doc, "``#{field}``"),
             "agent frontmatter field #{inspect(field)} is missing from #{@reference}"
    end
  end

  test "the sandbox mount keys are documented", %{doc: doc} do
    source = File.read!(Path.expand("lib/coding_agent/core/sandbox/mounts.ex", File.cwd!()))

    for key <- scan([source], ~r/dedup\([^)]*,\s*:([a-z]+)\)/) do
      assert String.contains?(doc, "``#{key}``"),
             "sandbox mount key #{inspect(key)} is missing from #{@reference}"
    end
  end

  test "every command in the registry is documented" do
    page = File.read!(Path.expand("docs/source/reference/commands.rst", File.cwd!()))

    for command <- CodingAgent.UI.Commands.all() do
      assert String.contains?(page, "``#{command.usage}``"),
             "command #{inspect(command.name)} (#{command.usage}) is missing from commands.rst"
    end
  end

  test "every documented usage line is a real registry command" do
    page = File.read!(Path.expand("docs/source/reference/commands.rst", File.cwd!()))

    documented =
      Regex.scan(~r/``(\/[a-z]+(?: \[[a-z|]+\])?)``/, page, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    known = Enum.map(CodingAgent.UI.Commands.all(), & &1.usage)

    for usage <- documented do
      assert usage in known,
             "commands.rst documents #{usage}, which is not in the registry"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp lib_sources do
    Path.wildcard(Path.expand("lib/**/*.ex", File.cwd!()))
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.map(&File.read!/1)
  end

  defp scan(sources, regex) do
    sources
    |> Enum.flat_map(fn source -> Regex.scan(regex, source, capture: :all_but_first) end)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end
end
