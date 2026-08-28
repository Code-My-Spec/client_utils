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
      state = %{port: nil, url: nil, mode: :quick, endpoint: nil, otp_app: nil}
      assert {:reply, nil, ^state} = CloudflareTunnel.handle_call(:url, self(), state)
    end

    test "returns URL when available (quick mode)" do
      url = "https://test-tunnel.trycloudflare.com"
      state = %{port: nil, url: url, mode: :quick, endpoint: nil, otp_app: nil}
      assert {:reply, ^url, ^state} = CloudflareTunnel.handle_call(:url, self(), state)
    end

    test "returns URL when available (named mode)" do
      url = "https://dev.myapp.com"
      state = %{port: nil, url: url, mode: :named, endpoint: nil, otp_app: nil}
      assert {:reply, ^url, ^state} = CloudflareTunnel.handle_call(:url, self(), state)
    end
  end

  describe "init/1" do
    test "returns :ignore when cloudflared is not in PATH" do
      existing = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent")

        assert :ignore =
                 CloudflareTunnel.init(
                   origin_url: "http://127.0.0.1:4000",
                   endpoint: Foo,
                   otp_app: :foo
                 )
      after
        System.put_env("PATH", existing)
      end
    end

    test "returns :ignore for named mode when tunnel_secret is nil" do
      existing = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent")

        assert :ignore =
                 CloudflareTunnel.init(
                   mode: :named,
                   hostname: "dev.example.com",
                   tunnel_id: "test-id",
                   account_tag: "test-tag",
                   origin_url: "http://127.0.0.1:4000",
                   endpoint: Foo,
                   otp_app: :foo
                 )
      after
        System.put_env("PATH", existing)
      end
    end

    test "returns :ignore for named mode when tunnel_secret is empty" do
      existing = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent")

        assert :ignore =
                 CloudflareTunnel.init(
                   mode: :named,
                   tunnel_secret: "",
                   hostname: "dev.example.com",
                   tunnel_id: "test-id",
                   account_tag: "test-tag",
                   origin_url: "http://127.0.0.1:4000",
                   endpoint: Foo,
                   otp_app: :foo
                 )
      after
        System.put_env("PATH", existing)
      end
    end
  end

  describe "terminate/2" do
    @moduledoc """
    Reported by the agent working in broken_oaths, 2026-08-28: killing the app
    left cloudflared running and still serving.

    `Port.close/1` shuts the port's stdin, which ends a child that reads stdin.
    cloudflared does not, so it outlived every restart. For a named tunnel the
    orphan keeps its connections registered and Cloudflare goes on routing to
    it, so a share of requests are answered by a tunnel whose origin is gone.

    Tested with `sleep` rather than cloudflared: the mechanism under test is
    "does the OS process die", and depending on cloudflared being installed
    would make this a test that silently skips on the machines most likely to
    regress it.
    """

    test "kills the OS process, not just the port" do
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")},
          args: ["60"]
        )

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      assert alive?(os_pid), "the probe never started; nothing was proven either way"

      CloudflareTunnel.terminate(:shutdown, %{port: port})

      refute eventually_dead?(os_pid),
             "cloudflared (pid #{os_pid}) outlived the app that started it. " <>
               "Closing the port is not enough -- it shuts stdin, and cloudflared " <>
               "never reads stdin, so it goes on serving a dead origin."
    end

    test "survives a state with no live port" do
      port = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["60"])
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      Port.close(port)
      System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)

      # A port already gone must not crash the shutdown path: terminate/2 runs
      # while things are being torn down, and raising here would skip whatever
      # cleanup came after it.
      assert CloudflareTunnel.terminate(:shutdown, %{port: port}) == :ok
    end
  end

  defp alive?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end

  # SIGTERM is delivered asynchronously, so this waits rather than asserting on
  # the instant after. Returns true only if it is still alive at the deadline.
  defp eventually_dead?(os_pid, attempts \\ 50) do
    Enum.reduce_while(1..attempts, true, fn _, _ ->
      if alive?(os_pid) do
        Process.sleep(20)
        {:cont, true}
      else
        {:halt, false}
      end
    end)
  end
end
