defmodule ClientUtils.CloudflareTunnel do
  @moduledoc """
  GenServer that manages a Cloudflare Tunnel process via an Erlang port.

  Supports two modes:

  ## Quick tunnel (default)

  Runs `cloudflared tunnel --url <origin>` which assigns a random
  `*.trycloudflare.com` URL — no account, credentials, or DNS required.

  The GenServer parses the tunnel URL from cloudflared's stdout and
  reconfigures the Phoenix endpoint so URL helpers generate correct
  public URLs.

      {ClientUtils.CloudflareTunnel,
        origin_url: "http://127.0.0.1:4000",
        endpoint: MyAppWeb.Endpoint,
        otp_app: :my_app}

  ## Named tunnel

  Uses a pre-configured Cloudflare named tunnel with a fixed hostname.
  Requires credentials and DNS configured in Cloudflare dashboard.

      {ClientUtils.CloudflareTunnel,
        mode: :named,
        hostname: "dev.myapp.com",
        tunnel_id: "...",
        account_tag: "...",
        tunnel_secret: "...",
        origin_url: "http://127.0.0.1:4000",
        endpoint: MyAppWeb.Endpoint,
        otp_app: :my_app}

  ## Required opts (both modes)

    * `:origin_url` — local origin URL (e.g. `"http://127.0.0.1:4000"`)
    * `:endpoint` — Phoenix Endpoint module (e.g. `MyAppWeb.Endpoint`)
    * `:otp_app` — OTP app atom (e.g. `:my_app`)

  ## Additional required opts (named mode)

    * `:hostname` — public hostname for the tunnel
    * `:tunnel_id` — Cloudflare tunnel UUID
    * `:account_tag` — Cloudflare account tag
    * `:tunnel_secret` — tunnel credential secret (base64)

  ## Optional opts

    * `:enabled` — `true` (default) or `false`; when `false`, the tunnel is not started
    * `:mode` — `:quick` (default) or `:named`
    * `:name` — GenServer name registration (default: `__MODULE__`)
    * `:additional_hostnames` — list of extra hostnames to route through the tunnel
      (named mode only). A bare hostname routes to the same origin as `:hostname`;
      a `{hostname, service}` tuple routes to `service` instead, for a second
      listener on the same machine. Each hostname is added as an ingress rule
      pointing to
      the same `:origin_url`. Useful for white-label custom domains in dev.
  """

  use GenServer
  require Logger

  @url_regex ~r"https://[a-z0-9-]+\.trycloudflare\.com"

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current tunnel URL, or nil if not yet established."
  def url, do: url(__MODULE__)

  @doc "Returns the current tunnel URL for the given server name."
  def url(name), do: GenServer.call(name, :url)

  @doc false
  def parse_url(line) do
    case Regex.run(@url_regex, line) do
      [url] -> url
      nil -> nil
    end
  end

  @impl true
  def init(opts) do
    # Trapping exits so `terminate/2` runs on a supervisor shutdown. Without it
    # the callback is skipped entirely and cloudflared is orphaned: the BEAM
    # closes the port, cloudflared never reads stdin so it never notices, and it
    # goes on serving after the app that started it is gone.
    #
    # For a named tunnel that is worse than a leak. The orphan keeps its
    # connections registered, so Cloudflare load-balances across it and the new
    # instance both, and a share of every request is answered by a tunnel whose
    # origin is dead. Restart twice and most of your preview is served by
    # processes nobody knows are running.
    Process.flag(:trap_exit, true)

    if Keyword.get(opts, :enabled, true) == false do
      Logger.info("[CloudflareTunnel] Tunnel disabled via :enabled option")
      :ignore
    else
      do_init(opts)
    end
  end

  defp do_init(opts) do
    case System.find_executable("cloudflared") do
      nil ->
        Logger.warning("[CloudflareTunnel] cloudflared not found in PATH — tunnel disabled")
        :ignore

      cloudflared ->
        mode = Keyword.get(opts, :mode, :quick)
        init_mode(mode, cloudflared, opts)
    end
  end

  defp init_mode(:quick, cloudflared, opts) do
    origin_url = Keyword.fetch!(opts, :origin_url)
    endpoint = Keyword.fetch!(opts, :endpoint)
    otp_app = Keyword.fetch!(opts, :otp_app)

    Logger.info("[CloudflareTunnel] Starting quick tunnel for #{origin_url}")

    # Pass --config pointing at a project-local empty file so cloudflared
    # ignores any global ~/.cloudflared/config.yml that another project may
    # have left behind (its catch-all ingress would 404 every quick tunnel
    # request — see https://github.com/cloudflare/cloudflared/issues/...).
    config_path = write_empty_config(opts)

    port =
      Port.open(
        {:spawn_executable, cloudflared},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [
            "--config",
            config_path,
            "tunnel",
            "--no-autoupdate",
            "--url",
            origin_url
          ]
        ]
      )

    {:ok, %{port: port, url: nil, mode: :quick, endpoint: endpoint, otp_app: otp_app}}
  end

  defp init_mode(:named, cloudflared, opts) do
    if opts[:tunnel_secret] in [nil, ""] do
      Logger.warning("[CloudflareTunnel] No tunnel_secret configured — tunnel disabled")
      :ignore
    else
      hostname = Keyword.fetch!(opts, :hostname)
      endpoint = Keyword.fetch!(opts, :endpoint)
      otp_app = Keyword.fetch!(opts, :otp_app)

      config_path = write_config(opts)
      Logger.info("[CloudflareTunnel] Starting named tunnel → https://#{hostname}")

      port =
        Port.open(
          {:spawn_executable, cloudflared},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["--config", config_path, "tunnel", "--no-autoupdate", "run"]
          ]
        )

      url = "https://#{hostname}"
      configure_endpoint(url, %{endpoint: endpoint, otp_app: otp_app})

      {:ok, %{port: port, url: url, mode: :named, endpoint: endpoint, otp_app: otp_app}}
    end
  end

  @impl true
  def handle_call(:url, _from, state) do
    {:reply, state.url, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    for line <- String.split(data, "\n", trim: true) do
      Logger.debug("[CloudflareTunnel] #{line}")
    end

    state =
      if state.mode == :quick and is_nil(state.url) do
        case parse_url(data) do
          nil ->
            state

          url ->
            Logger.info("[CloudflareTunnel] Tunnel ready → #{url}")
            configure_endpoint(url, state)
            %{state | url: url}
        end
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[CloudflareTunnel] Process exited with status #{status}")
    {:stop, {:tunnel_exit, status}, state}
  end

  # Arrives because we trap exits. Both are shutdown paths, not faults: the
  # first is the port going away, the second is the supervisor asking us to
  # stop. Neither is an error to report, and without these clauses the
  # GenServer dies of a FunctionClauseError on its way out -- which skips
  # `terminate/2` and orphans the very process the trap was added to reap.
  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  # Anything else is not worth dying for.
  def handle_info(_message, state), do: {:noreply, state}

  # Kill the OS process, then close the port -- in that order, because
  # `Port.info/2` stops answering once the port is closed and the pid is the one
  # thing we cannot recover afterwards.
  #
  # `Port.close/1` alone does not end cloudflared. Closing a port shuts its
  # stdin, which is enough for a child that reads stdin; cloudflared does not,
  # so it survives its parent indefinitely.
  #
  # SIGTERM rather than SIGKILL: cloudflared unregisters its connections on
  # SIGTERM, so Cloudflare stops routing to it immediately instead of waiting
  # out a health check. Nothing in-process can help if the BEAM itself is
  # SIGKILLed -- that orphan is unavoidable and is why `cms.new`'s template
  # names the tunnel deterministically rather than trusting what is running.
  @impl true
  def terminate(_reason, %{port: port}) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        Logger.info("[CloudflareTunnel] Stopping cloudflared (pid #{os_pid})")
        System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp configure_endpoint(url, %{endpoint: endpoint, otp_app: otp_app}) do
    uri = URI.parse(url)

    current = Application.get_env(otp_app, endpoint, [])
    updated = Keyword.put(current, :url, host: uri.host, scheme: uri.scheme, port: 443)
    Application.put_env(otp_app, endpoint, updated)

    if function_exported?(endpoint, :config_change, 2) do
      endpoint.config_change([{endpoint, updated}], [])
    end
  end

  # A hostname alone routes to the same origin as the main one. A
  # `{hostname, service}` pair routes somewhere else, which is what a second
  # listener on the same machine needs — one app cannot always serve every
  # hostname the tunnel carries, and forcing it to is how you end up with a
  # path collision that only shows up over WebSocket.
  defp ingress_rule({host, service}, _default),
    do: "  - hostname: #{quoted(host)}\n    service: #{service}"

  defp ingress_rule(host, default), do: "  - hostname: #{quoted(host)}\n    service: #{default}"

  # Quoted, because a wildcard hostname starts with `*` and an unquoted `*` in
  # YAML is an alias indicator — cloudflared refuses to parse the whole file,
  # which takes down every other route with it rather than just the new one.
  defp quoted(host), do: ~s("#{host}")

  defp write_config(opts) do
    base_dir = Keyword.get(opts, :base_dir, Path.join(File.cwd!(), "tmp/cloudflared"))
    File.mkdir_p!(base_dir)
    credentials_path = write_credentials(opts, base_dir)

    additional = Keyword.get(opts, :additional_hostnames, [])

    extra_ingress =
      additional
      |> Enum.map(&ingress_rule(&1, opts[:origin_url]))
      |> Enum.join("\n")

    extra_block = if extra_ingress == "", do: "", else: "\n" <> extra_ingress

    yaml = """
    tunnel: #{opts[:tunnel_id]}
    credentials-file: #{credentials_path}

    ingress:
      - hostname: #{opts[:hostname]}
        service: #{opts[:origin_url]}#{extra_block}
      - service: http_status:404
    """

    # Write to the project's tmp/cloudflared dir (not ~/.cloudflared) so
    # multiple projects can run named tunnels on the same machine without
    # clobbering each other's config — and so a quick tunnel from any
    # project isn't poisoned by a leftover ingress rule.
    config_dir = Keyword.get(opts, :config_dir, base_dir)
    File.mkdir_p!(config_dir)
    path = Path.join(config_dir, "config.yml")
    File.write!(path, yaml)
    path
  end

  defp write_empty_config(opts) do
    base_dir = Keyword.get(opts, :base_dir, Path.join(File.cwd!(), "tmp/cloudflared"))
    File.mkdir_p!(base_dir)
    path = Path.join(base_dir, "quick_config.yml")
    # cloudflared rejects a fully empty file; a no-op key keeps it valid.
    File.write!(path, "no-autoupdate: true\n")
    path
  end

  defp write_credentials(opts, base_dir) do
    json =
      Jason.encode!(%{
        "AccountTag" => opts[:account_tag],
        "TunnelSecret" => opts[:tunnel_secret],
        "TunnelID" => opts[:tunnel_id],
        "Endpoint" => ""
      })

    path = Path.join(base_dir, "credentials.json")
    File.write!(path, json)
    path
  end
end
