defmodule CodingAgent.TestCatalogFetch do
  @moduledoc """
  Test transport for the catalog refresh (ADR 039 amendment 2026-10-18 (2)).

  `Catalog.Refresh` reaches its transport through the `:catalog_refresh` app
  env — a `{module, function, args}` triple, so a test can drive the whole
  `Catalog` lifecycle (warm, timer, `/catalog`) with local documents and never
  download the 11 MB release document. The response is a plain app-env value
  rather than a closure: `Catalog` reads the transport from configuration
  inside its own process, where a test's closure would not exist.

  Lives in test/support (compiled) for the same reason the sandbox stub does:
  it is named in configuration, and a module the loader has to find must be
  on the code path.
  """

  @env :catalog_refresh_test_response

  @doc """
  The configured response, in the shape llm_db's release store answers with
  (`%{snapshot: document, snapshot_id: id}`). A bare `{:error, reason}` is
  passed through, so a test can exercise a failing fetch.
  """
  def call do
    case Application.get_env(:coding_agent, @env, {:error, :no_test_response}) do
      {:ok, %{} = document} ->
        {:ok, %{snapshot: document, snapshot_id: document["snapshot_id"]}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:ok, other}
    end
  end

  @doc "Sets the response `call/0` will answer with."
  def respond(value), do: Application.put_env(:coding_agent, @env, value)

  @doc "Restores the response a previous test had configured (nil: none)."
  def restore(nil), do: Application.delete_env(:coding_agent, @env)
  def restore(value), do: Application.put_env(:coding_agent, @env, value)

  @doc "The currently configured response, for an `on_exit` restore."
  def response, do: Application.get_env(:coding_agent, @env)
end
