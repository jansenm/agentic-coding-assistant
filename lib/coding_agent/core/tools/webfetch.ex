defmodule CodingAgent.Core.Tools.WebFetch do
  @max_bytes 128 * 1024
  @timeout_ms 15_000

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
  """

  alias CodingAgent.Core.Tools

  @spec tool(Tools.scope()) :: ReqLLM.Tool.t()
  def tool(_scope) do
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
      callback: fn args -> execute(args) end
    )
  end

  defp execute(args) do
    url = Map.get(args, :url) || Map.get(args, "url")

    with {:ok, parsed} <- parse_url(url),
         :ok <- check_host(parsed) do
      fetch(parsed)
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
  # the connect — accepted for v1.
  defp check_host(%URI{host: host}) do
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

  defp fetch(uri) do
    url = URI.to_string(uri)

    case Req.get(url,
           redirect: :follow,
           max_redirects: 5,
           receive_timeout: @timeout_ms,
           max_retries: 0,
           retry: :safe_transient
         ) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}}
      when status in 200..299 ->
        content_type = content_type(headers)

        cond do
          text?(content_type) ->
            {:ok, body |> to_text(content_type) |> cap()}

          true ->
            Tools.error("refusing content type #{inspect(content_type)} — text only")
        end

      {:ok, %Req.Response{status: status}} ->
        Tools.error("HTTP #{status}")

      {:error, err} ->
        Tools.error("fetch failed: #{Exception.message(err)}")
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

  defp text?(type) do
    String.starts_with?(type, "text/") or
      type in ["application/json", "application/xml", "application/xhtml+xml"]
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

  defp cap(text) when byte_size(text) <= @max_bytes, do: text

  defp cap(text) do
    <<head::binary-size(@max_bytes), _::binary>> = text
    head <> "\n\n… (truncated at #{div(@max_bytes, 1024)} KiB)"
  end
end
