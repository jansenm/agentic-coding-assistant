# SPDX-FileCopyrightText: 2026 Michael Jansen <ferroclass@michael-jansen.biz>
#
# SPDX-License-Identifier: MPL-2.0

defmodule CodingAgent.Core.Tools.WebFetch do
  @max_bytes 128 * 1024
  @timeout_ms 15_000
  # hop budget for the manual redirect loop (was Req's max_redirects)
  @max_redirects 5
  @redirect_statuses [301, 302, 303, 307, 308]

  @private_v4 [
    {127, 0, 0, 0, 8},
    {10, 0, 0, 0, 8},
    {172, 16, 0, 0, 12},
    {192, 168, 0, 0, 16},
    {169, 254, 0, 0, 16}
  ]

  @moduledoc """
  Network read tool (slice 7a), per ADR 013: always-ask in v1, scheme
  allowlist (http/https), private-network block (SSRF), 128 KiB cap,
  15 s timeout, no retries. HTML is de-tagged; binary types refused.

  Redirects are followed MANUALLY (`redirect: false` + our own hop
  loop) so the SSRF guard re-runs on every hop. Req's own
  `redirect: :follow` validated only the first URL: a public page could
  302 to `169.254.169.254` and the fetch would obey.
  Each `Location` is resolved against the current URL, re-parsed
  (scheme allowlist) and re-checked with `check_host/1`; the hop budget
  is bounded by `@max_redirects`.
  """

  alias CodingAgent.Core.Tools

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(scope) do
    ReqLLM.Tool.new!(
      name: "webfetch",
      description:
        "Fetch a public web page (http/https) and return its text. " <>
          "HTML is stripped to plain text; the body is capped at " <>
          "#{div(@max_bytes, 1024)} KiB. Local/private network addresses " <>
          "are refused. Subject to the permission policy; requires approval.",
      parameter_schema: [
        url: [type: :string, required: true, doc: "The http(s) URL to fetch"]
      ],
      callback: fn args -> execute(args, scope) end
    )
  end

  defp execute(args, scope) do
    url = Map.get(args, :url) || Map.get(args, "url")

    with {:ok, parsed} <- parse_url(url) do
      # every hop (the first included) passes check_host inside fetch/1
      fetch(parsed, scope)
    end
  end

  # -- URL validation ---------------------------------------------------------

  defp parse_url(url) when is_binary(url) do
    case try_parse(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, uri}

      {:ok, %URI{scheme: scheme}} when scheme in ["http", "https"] ->
        Tools.error("URL has no host: #{inspect(url)}")

      {:ok, %URI{scheme: scheme}} ->
        Tools.error("scheme not allowed: #{inspect(scheme)} (http/https only)")

      _ ->
        Tools.error("not a valid URL: #{inspect(url)}")
    end
  end

  defp parse_url(url), do: Tools.error("url must be a string, got: #{inspect(url)}")

  # URI.new raises on malformed input ("http:///path") — the guard
  # clauses inside try_parse cover that too
  defp try_parse(url) do
    URI.new(url)
  rescue
    _ -> :error
  end

  # SSRF guard (ADR 013): resolve and refuse private ranges. The
  # documented residual risk is DNS rebinding between this check and
  # the connect — accepted for v1. Public for tests (@doc false): the
  # guard is the security boundary, so it is asserted directly without
  # a real fetch.
  @doc false
  @spec check_host(URI.t()) :: :ok | {:error, String.t()}
  def check_host(%URI{host: host}) do
    host = host |> URI.decode()

    cond do
      host in ["localhost", "0.0.0.0"] ->
        Tools.error("refusing local address: #{host}")

      ip? = Regex.match?(~r/^[0-9.]+$/, host) ->
        reject_if_private_v4(host, ip?)

      true ->
        case :inet.gethostbyname(String.to_charlist(host)) do
          {:ok, {:hostent, _, _, _, _, [addr | _]}} ->
            reject_if_private_ip(addr, host)

          _ ->
            # unresolved: let the request fail with its own error
            :ok
        end
    end
  end

  defp reject_if_private_v4(host, _true) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, addr} -> reject_if_private_ip(addr, host)
      _ -> :ok
    end
  end

  defp reject_if_private_ip(addr, _host) when is_tuple(addr) and tuple_size(addr) == 4 do
    if Enum.any?(@private_v4, fn private -> in_v4?(addr, private) end) do
      Tools.error("refusing private network address: #{:inet.ntoa(addr)}")
    else
      :ok
    end
  end

  defp reject_if_private_ip(addr, host) when tuple_size(addr) == 8 do
    private_v6? =
      elem(addr, 0) == 0 or
        elem(addr, 0) in [0xFC, 0xFD] or
        (elem(addr, 0) == 0xFE and elem(addr, 1) >= 0x80) or
        addr == {0, 0, 0, 0, 0, 0, 0, 1}

    if private_v6? do
      Tools.error("refusing private network address: #{host}")
    else
      :ok
    end
  end

  defp reject_if_private_ip(_addr, _host), do: :ok

  import Bitwise

  # private = {a, b, c, d, mask_bits} — 5-tuples (readable, one less unpack)
  defp in_v4?({a, b, c, d}, {ea, eb, ec, ed, mask}) do
    <<ip::32>> = <<a, b, c, d>>
    <<base::32>> = <<ea, eb, ec, ed>>
    band(ip, bmask(mask)) == band(base, bmask(mask))
  end

  # mask counts LEADING bits (CIDR style): 8 -> 0xFF000000
  defp bmask(mask), do: -1 <<< (32 - mask)

  # -- Fetch ------------------------------------------------------------------

  defp fetch(uri, scope), do: fetch(uri, @max_redirects, scope)

  defp fetch(uri, hops_left, scope) do
    # Re-check EVERY hop, not just the first: the Location is attacker
    # controlled, so a public URL redirecting to a private one must be
    # refused here.
    with :ok <- check_host(uri) do
      request(uri, hops_left, scope)
    end
  end

  defp request(uri, hops_left, scope) do
    case Req.get(URI.to_string(uri),
           redirect: false,
           receive_timeout: @timeout_ms,
           max_retries: 0,
           retry: :safe_transient,
           # Req's default decoder turns `application/json` into a Map.
           # Everything below this line is defined on bytes: `to_text/2`
           # matches on the content type, `cap/2` measures and slices.
           # A decoded Map ran `byte_size/1` inside the callback and
           # killed the tool with "not an iodata term" (P29) — and the
           # model wants the document, not an inspected term.
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status, headers: headers}}
      when status in @redirect_statuses ->
        follow(headers, uri, hops_left, scope)

      {:ok, %Req.Response{status: status, headers: headers, body: body}}
      when status in 200..299 ->
        render(headers, body, scope)

      {:ok, %Req.Response{status: status}} ->
        Tools.error("HTTP #{status}")

      {:error, err} ->
        Tools.error("fetch failed: #{Exception.message(err)}")
    end
  end

  # The body -> result mapping. Public for tests (@doc false): this is
  # where the JSON crash lived, and it is reachable without a socket.
  @doc false
  @spec render(list(), term(), Tools.scope()) :: {:ok, String.t()} | {:error, String.t()}
  def render(headers, body, scope) do
    type = content_type(headers)

    cond do
      not text?(type) ->
        Tools.error("refusing content type #{inspect(type)} — text only")

      # Unreachable while `decode_body: false` holds — which is the
      # point: the guard turns "a decoder ran where bytes are expected"
      # into a sentence naming the type, instead of Req's callback
      # dying with "not an iodata term" (P29).
      not is_binary(body) ->
        Tools.error("#{inspect(type)} arrived decoded — this tool returns text")

      true ->
        {:ok, body |> to_text(type) |> cap(scope)}
    end
  end

  # Manual hop: resolve the Location against the current URL (relative
  # redirects), re-parse it through the scheme allowlist, then recurse
  # with one fewer hop. fetch/2 re-runs check_host on the resolved URI.
  # Public for tests (@doc false): the hop seam returns BEFORE any
  # request, so the SSRF re-check is asserted offline.
  @doc false
  def follow(_headers, _uri, 0, _scope), do: Tools.error("too many redirects")

  def follow(headers, uri, hops_left, scope) do
    case location(headers) do
      nil ->
        Tools.error("redirect without a Location header")

      location ->
        with {:ok, resolved} <- resolve_location(uri, location) do
          fetch(resolved, hops_left - 1, scope)
        end
    end
  end

  # Merge a (possibly relative) Location against the current URL and run
  # the scheme allowlist. Public for tests (@doc false): this is the
  # re-parse boundary, and asserting it network-free is what lets the
  # redirect tests cover the check without a live hop.
  @doc false
  def resolve_location(uri, location) do
    merged = URI.merge(uri, URI.parse(location))
    parse_url(URI.to_string(merged))
  rescue
    # a malformed Location must fail closed, never raise out of the tool
    _ -> Tools.error("invalid redirect location: #{inspect(location)}")
  end

  defp location(headers) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == "location" end)
    |> case do
      {_, [v | _]} -> v
      {_, v} when is_binary(v) -> v
      _ -> nil
    end
  end

  defp content_type(headers) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
    |> case do
      {_, [v | _]} -> v |> String.split(";") |> List.first() |> String.trim()
      _ -> "application/octet-stream"
    end
  end

  # `text/*`, the two XML forms, JSON — and every `+json` type: RFC 6839
  # makes the suffix the registration, so `application/problem+json` and
  # `application/vnd.oai.openapi+json` are JSON documents, not archives
  # (P30). An exact-type list cannot say that; it refused the OpenAPI
  # document of llmcatalog.dev while accepting `application/json`.
  defp text?(type) do
    String.starts_with?(type, "text/") or
      type in ["application/json", "application/xml", "application/xhtml+xml"] or
      String.ends_with?(type, "+json")
  end

  defp to_text(body, "text/html"), do: strip_html(body)
  defp to_text(body, "application/xhtml+xml"), do: strip_html(body)
  defp to_text(body, _), do: body

  # Minimal de-tagging (ADR 013: not a markdown conversion). Drops
  # script/style entirely, removes tags, decodes the common entities.
  # Test-only visibility (@doc false, not @impl — not part of the
  # tool contract).
  @doc false
  def strip_html(html) do
    html
    |> String.replace(~r/<script[\s\S]*?<\/script>/i, "")
    |> String.replace(~r/<style[\s\S]*?<\/style>/i, "")
    |> String.replace(~r/<br\s*\/?>|<\/p>|<\/div>|<\/li>|<\/h[1-6]>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp cap(text, _scope) when byte_size(text) <= @max_bytes, do: text

  defp cap(text, scope) do
    spilled =
      case CodingAgent.Core.Spill.spill(text, Tools.profile(scope), "webfetch") do
        {:ok, path} -> " (full text at #{path})"
        _ -> ""
      end

    <<head::binary-size(@max_bytes), _::binary>> = text
    head <> "\n\n… (truncated at #{div(@max_bytes, 1024)} KiB#{spilled})"
  end
end
