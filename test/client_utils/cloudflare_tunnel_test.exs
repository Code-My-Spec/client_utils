defmodule ClientUtils.CloudflareTunnelTest do
  use ExUnit.Case, async: true

  alias ClientUtils.CloudflareTunnel

  describe "parse_url/1" do
    test "extracts URL from typical cloudflared log line" do
      line =
        "2024-01-15T10:00:00Z INF +-------------------------------------------+\n" <>
          "2024-01-15T10:00:00Z INF |  https://foo-bar-baz.trycloudflare.com    |\n"

      assert CloudflareTunnel.parse_url(line) ==
               "https://foo-bar-baz.trycloudflare.com"
    end

    test "extracts URL with numbers in subdomain" do
      line = "INF https://abc-123-def.trycloudflare.com registered"

      assert CloudflareTunnel.parse_url(line) ==
               "https://abc-123-def.trycloudflare.com"
    end

    test "returns nil for lines without a tunnel URL" do
      assert is_nil(CloudflareTunnel.parse_url("INF Starting tunnel"))
      assert is_nil(CloudflareTunnel.parse_url("INF Connection established"))
      assert is_nil(CloudflareTunnel.parse_url(""))
    end

    test "returns nil for non-trycloudflare URLs" do
      assert is_nil(CloudflareTunnel.parse_url("https://example.com"))
      assert is_nil(CloudflareTunnel.parse_url("https://fake-trycloudflare.com"))
    end
  end

  describe "handle_call :url" do
    test "returns nil when URL not yet parsed" do
      state = %{port: nil, url: nil, endpoint: nil, otp_app: nil}
      assert {:reply, nil, ^state} = CloudflareTunnel.handle_call(:url, self(), state)
    end

    test "returns URL when available" do
      url = "https://test-tunnel.trycloudflare.com"
      state = %{port: nil, url: url, endpoint: nil, otp_app: nil}
      assert {:reply, ^url, ^state} = CloudflareTunnel.handle_call(:url, self(), state)
    end
  end

  describe "init/1" do
    test "returns :ignore when cloudflared is not in PATH" do
      existing = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent")
        assert :ignore = CloudflareTunnel.init(origin_url: "http://127.0.0.1:4000", endpoint: Foo, otp_app: :foo)
      after
        System.put_env("PATH", existing)
      end
    end
  end
end
