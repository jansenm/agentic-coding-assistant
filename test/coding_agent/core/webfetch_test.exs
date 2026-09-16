defmodule CodingAgent.Core.Tools.WebFetchTest do
  use ExUnit.Case, async: true

  @tmp_root System.tmp_dir!() |> Path.join("agent-webfetch-#{System.unique_integer()}")

  setup do
    File.mkdir_p!(@tmp_root)
    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    %{scope: %{root: @tmp_root}}
  end

  describe "URL validation (network-free refusals)" do
    test "file:// is refused before any request" do
      tool = CodingAgent.Core.Tools.WebFetch.tool(nil)

      {:error, msg} = ReqLLM.Tool.execute(tool, %{"url" => "file:///etc/passwd"})
      assert msg =~ "scheme not allowed"
    end

    test "ftp:// and custom schemes refused" do
      tool = CodingAgent.Core.Tools.WebFetch.tool(nil)

      {:error, msg} = ReqLLM.Tool.execute(tool, %{"url" => "ftp://example.com/x"})
      assert msg =~ "scheme not allowed"
    end

    test "URL without host refused" do
      tool = CodingAgent.Core.Tools.WebFetch.tool(nil)

      # URI.new raises on this shape; the tool (or req_llm's schema
      # coercion) refuses either way — inspect normalizes the wrapped
      # error struct to a string for matching
      {:error, msg} = ReqLLM.Tool.execute(tool, %{"url" => "http:///path"})

      assert inspect(msg) =~ "no host" or inspect(msg) =~ "not a valid URL" or
               inspect(msg) =~ "host is required"
    end

    test "localhost refused" do
      tool = CodingAgent.Core.Tools.WebFetch.tool(nil)

      {:error, msg} = ReqLLM.Tool.execute(tool, %{"url" => "http://localhost:4000/dashboard"})
      assert msg =~ "refusing local address"
    end

    test "private IPv4 literal refused (SSRF)" do
      tool = CodingAgent.Core.Tools.WebFetch.tool(nil)

      Enum.each(
        [
          "http://127.0.0.1:8080/x",
          "http://10.1.2.3/x",
          "http://192.168.1.50/admin",
          "http://172.20.0.1/x",
          # the AWS metadata endpoint — explicitly covered (ADR 013)
          "http://169.254.169.254/latest/meta-data/"
        ],
        fn url ->
          {:error, msg} = ReqLLM.Tool.execute(tool, %{"url" => url})
          assert msg =~ "refusing private network address"
        end
      )
    end

    test "public IPv4 literal passes the host check (guarded directly, no fetch)" do
      # 93.184.216.34 (example.com historically) — the host check must
      # NOT refuse it. Asserted through the guard seam (check_host/1)
      # rather than a real fetch: the point is the verdict, not the
      # network round-trip (a live fetch here cost ~5 s per run).
      assert :ok = CodingAgent.Core.Tools.WebFetch.check_host(%URI{host: "93.184.216.34"})
      assert :ok = CodingAgent.Core.Tools.WebFetch.check_host(%URI{host: "8.8.8.8"})
    end
  end

  describe "registered as gated (always-ask, ADR 013)" do
    test "webfetch is in the gated tool list" do
      tools = CodingAgent.Core.Tools.gated(%{root: @tmp_root})
      assert Enum.any?(tools, &(&1.name == "webfetch"))

      # and NOT in the read-only list — a network tool is never
      # allow-by-policy
      refute Enum.any?(
               CodingAgent.Core.Tools.read_only(%{root: @tmp_root}),
               &(&1.name == "webfetch")
             )
    end

    test "policy default is ask" do
      assert CodingAgent.Core.Permissions.default_for("webfetch") == :ask
    end
  end

  describe "HTML de-tagging (no network)" do
    test "script/style dropped, tags removed, entities decoded" do
      html =
        "<html><head><style>p{}</style><script>alert(1)</script></head>" <>
          "<body><h1>Title</h1><p>A &amp; B</p><ul><li>x</li></ul></body></html>"

      assert apply_private(:strip_html, [html]) =~ "Title"
      assert apply_private(:strip_html, [html]) =~ "A & B"
      refute apply_private(:strip_html, [html]) =~ "alert"
      refute apply_private(:strip_html, [html]) =~ "<p>"
    end
  end

  defp apply_private(fun, args), do: :erlang.apply(CodingAgent.Core.Tools.WebFetch, fun, args)
end
